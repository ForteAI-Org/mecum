import ChatCore
import AutomationRuntime
import EngineCore
import Foundation
import Memory
import ModelTransports
import Testing
@testable import Mecum

/// Runs the real worker and tool cycle with invented scenes and an in-process model.
@MainActor
@Suite("Worker living memory", .serialized)
struct WorkerMemoryTests {
    private let request = "Select Output Busses in All Busses"
    private let selection = ModelSelection(provider: .ollama, model: "synthetic", effort: .high)
    private let usage = ModelUsage(inputTokens: nil, outputTokens: nil, duration: .zero)

    private func transport(for session: MemoryTestSession) throws -> MemoryTestTransport {
        let sessionID = try #require(session.id).uuidString
        let call = ToolCall(
            id: "select-1",
            name: "select",
            arguments: Data("{\"session\":\"\(sessionID)\",\"control\":\"All Busses\",\"item\":\"Output Busses\"}".utf8)
        )
        return MemoryTestTransport(
            supportsTools: true,
            rounds: [[.toolCall(call), .completed(usage)], [.delta("Done"), .completed(usage)]]
        )
    }

    private func host(
        store: InMemoryLivingMemoryStore,
        session: MemoryTestSession,
        transport: MemoryTestTransport
    ) -> WorkerAgentHost {
        WorkerAgentHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-worker-memory-\(UUID())"),
            bridgeExecutable: URL(filePath: "/synthetic-unused-bridge"),
            session: { session },
            livingMemory: store,
            transports: { _ in transport }
        )
    }

    @Test func aVerifiedStepIsRecalledByAnotherWorkerWithoutLearningTheQuote() async throws {
        let store = InMemoryLivingMemoryStore()
        let session = MemoryTestSession()
        let firstTransport = try transport(for: session)
        let first = host(store: store, session: session, transport: firstTransport)
        var events: [WorkerAgentEvent] = []
        let quotedPrompt = "Quoted context: never store this quote.\n\n" + request
        try await first.run(
            prompt: quotedPrompt,
            learningRequest: request,
            selection: selection,
            sessionID: nil,
            role: nil
        ) { events.append($0) }
        try await first.close()
        let records = await store.experiences(in: ["test.synthetic.mixer"])
        #expect(records.count == 1)
        #expect(records.first?.phrase == request)
        #expect(records.first?.successCount == 1)
        #expect(firstTransport.sent.first?.messages.last?.text == quotedPrompt)
        #expect(events.contains { if case .tool(let text) = $0 { text.hasPrefix("memory: remembered") } else { false } })

        let nextSession = MemoryTestSession()
        let nextTransport = MemoryTestTransport(
            supportsTools: true,
            rounds: [[.delta("I will observe first."), .completed(usage)]]
        )
        let next = host(store: store, session: nextSession, transport: nextTransport)
        try await next.run(prompt: request, selection: selection, sessionID: nil, role: nil) { _ in }
        try await next.close()
        #expect(nextTransport.sent.first?.messages.last?.text.contains("<mecum-memory>") == true)
        #expect(nextSession.selections == 0)
        #expect(await store.experiences(in: ["test.synthetic.mixer"]).first?.successCount == 1)
    }

    @Test func stoppingAfterAnEffectDoesNotPromoteOrReplayIt() async throws {
        let store = InMemoryLivingMemoryStore()
        let session = MemoryTestSession()
        let transport = try transport(for: session)
        let worker = host(store: store, session: session, transport: transport)
        await #expect(throws: CancellationError.self) {
            try await worker.run(prompt: request, selection: selection, sessionID: nil, role: nil) { event in
                if case .tool(let text) = event, text.hasPrefix("← select ") { worker.stop() }
            }
        }
        try await worker.close()
        #expect(session.selections == 1)
        #expect(await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)
        #expect(!worker.isRunning)
    }

    @Test func closureWithoutAnAfterSceneIsLearnedByTheWorker() async throws {
        let store = InMemoryLivingMemoryStore()
        let session = MemoryTestSession()
        session.sceneLabels = ["Cancel"]
        session.sceneWindowTitle = "I/O Setup"
        let proof = ClickEvidence(bundleID: session.sceneBundleID, windowTitle: "I/O Setup", target: "Cancel",
                                  targetRole: "AXButton", section: nil, gesture: .click, delivery: .sent,
                                  effect: .windowClosed(title: "I/O Setup"))
        session.actOutcome = ActOutcome(.foundActed, "verified closure", evidence: .click(proof))
        let id = try #require(session.id).uuidString
        let call = ToolCall(id: "cancel-1", name: "act",
                           arguments: Data("{\"session\":\"\(id)\",\"target\":\"Cancel\",\"verb\":\"click\"}".utf8))
        let transport = MemoryTestTransport(supportsTools: true,
                                           rounds: [[.toolCall(call), .completed(usage)], [.delta("Closed"), .completed(usage)]])
        let worker = host(store: store, session: session, transport: transport)
        var events: [WorkerAgentEvent] = []
        try await worker.run(prompt: "1. Chiudi I/O Setup con Cancel e verifica che sia chiusa.",
                             selection: selection, sessionID: nil, role: nil) { events.append($0) }
        try await worker.close()
        let records = await store.experiences(in: [session.sceneBundleID])
        #expect(records.count == 1)
        #expect(records.first?.step.summary == "click 'Cancel' to close the window 'I/O Setup'")
        #expect(events.contains { if case .tool(let text) = $0 { text.hasPrefix("memory: remembered") } else { false } })
    }

    @Test func nativeMenuIsLearnedWithItsFullPath() async throws {
        let store = InMemoryLivingMemoryStore()
        let session = MemoryTestSession()
        let id = try #require(session.id).uuidString
        let args: [String: Any] = ["session": id, "path": ["Setup", "I/O..."], "expect_window": "I/O Setup"]
        let call = ToolCall(id: "menu-1", name: "menu", arguments: try JSONSerialization.data(withJSONObject: args))
        let transport = MemoryTestTransport(supportsTools: true,
            rounds: [[.toolCall(call), .completed(usage)], [.delta("Opened"), .completed(usage)]])
        let worker = host(store: store, session: session, transport: transport)
        try await worker.run(prompt: "Apri I/O Setup", selection: selection, sessionID: nil, role: nil) { _ in }
        try await worker.close()
        let records = await store.experiences(in: [session.sceneBundleID])
        #expect(records.count == 1)
        #expect(records.first?.step == .menu(MenuStep(path: ["Setup", "I/O..."], expectedWindow: "I/O Setup")))
    }

    @Test func missingMemoryDoesNotPreventAWorkerFromAnswering() async throws {
        let transport = MemoryTestTransport(supportsTools: true, rounds: [[.delta("Hello"), .completed(usage)]])
        let worker = WorkerAgentHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-memory-unavailable-\(UUID())"),
            bridgeExecutable: URL(filePath: "/synthetic-unused-bridge"),
            session: { MemoryTestSession() },
            transports: { _ in transport }
        )
        var events: [WorkerAgentEvent] = []
        try await worker.run(prompt: "Hello", selection: selection, sessionID: nil, role: nil) { events.append($0) }
        try await worker.close()
        #expect(events.contains(.provider(.assistant("Hello"))))
    }
}

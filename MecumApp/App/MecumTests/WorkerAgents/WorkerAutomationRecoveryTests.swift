import AutomationRuntime
import Foundation
import EngineCore
import ModelTransports
import Testing
@testable import Mecum

@MainActor
@Suite("Worker automation recovery", .serialized)
struct WorkerAutomationRecoveryTests {
    @Test func repeatedUnverifiedSelectionsStopTheProviderAndReleaseTheSession() async throws {
        let session = MemoryTestSession()
        session.readback = .window("All Busses")
        let id = try #require(session.id).uuidString
        let usage = ModelUsage(inputTokens: nil, outputTokens: nil, duration: .zero)
        let calls = (0..<4).map { index in
            ToolCall(id: "select-\(index)", name: "select", arguments: Data(
                "{\"session\":\"\(id)\",\"control\":\"All Busses\",\"item\":\"Output Busses\"}".utf8
            ))
        }
        let transport = MemoryTestTransport(supportsTools: true, rounds: [
            calls.map(TurnEvent.toolCall) + [.completed(usage)],
            [.delta("This round must never run"), .completed(usage)]
        ])
        let worker = WorkerAgentHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-recovery-\(UUID())"),
            bridgeExecutable: URL(filePath: "/synthetic-unused-bridge"),
            session: { session },
            transports: { _ in transport }
        )
        do {
            try await worker.run(
                prompt: "Select Output Busses",
                selection: .init(provider: .ollama, model: "synthetic", effort: .medium),
                sessionID: nil,
                role: nil
            ) { _ in }
            Issue.record("A stalled worker completed instead of reporting its stop reason")
        } catch {
            #expect((error as? AutomationFailure)?.description.contains("3 unsuccessful automation attempts") == true)
        }
        #expect(session.selections == 3)
        #expect(transport.sent.count == 1)
        #expect(session.id == nil)
        #expect(!worker.isRunning)
        try await worker.close()
    }
}

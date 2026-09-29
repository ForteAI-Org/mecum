//
//  LivingMemoryIntegrationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import AutomationMCP
import ChatCore
import CLIProviders
import EngineCore
import FileConversations
import FileKnowledge
import Foundation
import LocalMCP
import Memory
@testable import mecum
import SQLiteLivingMemory
import Testing

/// The whole learning and recall path, offline: two compositions of `mecum chat` over one knowledge
/// directory, each with its own store actor, brain store, session, tools and turn cycle, and two
/// separate chat conversations. They run one after the other in this test process, not as two
/// operating-system processes; a real restart is the live tier's. Only the Seat and the provider are
/// synthetic; the provider is the list of tool calls a model would make. Nothing is preloaded: the
/// second instance can only know what the first learned through the production path and wrote to disk.
@Suite("Learning, reopening and recalling through the production path", .serialized)
struct LivingMemoryIntegrationTests {

    private let learning = "Seleziona Output Busses nel filtro e verifica il nuovo valore. "
        + "Fermati se il controllo non è univoco."
    private let recalling = "Seleziona Output Busses nel filtro. Prima dimmi se hai "
        + "un’esperienza verificata che può aiutare; poi osserva la finestra attuale e agisci solo se il "
        + "controllo è presente."
    private let bundle = "test.synthetic.mixer"
    private let routing = "Synthetic I/O Setup"

    /// MecumProcess is what one `mecum chat` process composes, with a synthetic Seat. A new instance
    /// stands for a restart but runs in this test process.
    @MainActor
    private struct MecumProcess {
        let store: SQLiteLivingMemoryStore
        let brainStore: FileKnowledgeStore
        let session: IntakeSession
        let tools: AutomationTools
        let cycle: TurnCycle

        init(knowledge: URL, bundle: String, window: String, labels: [String]) throws {
            store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            brainStore = FileKnowledgeStore(directory: knowledge, clock: { Date() }, flushDelay: .seconds(3600),
                                            diagnostics: { _ in })
            let intake = SceneIntake(brain: BrainMemory(store: brainStore, clock: { Date() }), livingMemory: store)
            session = IntakeSession(intake: intake, bundleID: bundle, windowTitle: window, labels: labels)
            tools = AutomationTools(session: session)
            cycle = TurnCycle(tools: tools, livingMemory: store)
        }

        /// One provider turn: the cycle's begin, the model's tool calls, then the cycle's end.
        func turn(
            _ request: String,
            ending   : TurnAdmission.Ending = .completed,
            _ model  : (AutomationTools, IntakeSession) async throws -> Void
        ) async throws -> (TurnCycle.Start, TurnCycle.End) {
            let start = try await cycle.begin(request, sessionIsOpen: session.id != nil)
            try await model(tools, session)
            return (start, try #require(await cycle.end(ending)))
        }

        func close() async {
            await session.close()
            await brainStore.flush()
        }
    }

    // MARK: The model's tool calls

    @MainActor
    private static func openAndObserve(_ tools: AutomationTools, _ session: IntakeSession) async throws {
        _ = try await tools.call("status", .object([:]))
        if session.id == nil { _ = try await tools.call("open_session", .object(["app": .string("Synthetic")])) }
        _ = try await tools.call("observe", .object(["session": id(session)]))
    }

    @MainActor
    @discardableResult
    private static func select(_ tools: AutomationTools, _ session: IntakeSession) async throws -> JSONValue {
        try await tools.call("select", .object(["session": id(session), "control": .string("All Busses"),
                                                "item": .string("Output Busses")]))
    }

    @MainActor
    private static func id(_ session: IntakeSession) -> JSONValue {
        .string(session.id?.uuidString ?? "none")
    }

    private func withDirectories(_ body: (URL, ConversationStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = try ConversationStore(directory: root.appendingPathComponent("Conversations"))
        try await body(root.appendingPathComponent("Knowledge", isDirectory: true), conversations)
    }

    /// Runs the first instance: one admitted turn that changes the filter, then shutdown.
    @MainActor
    private func learnInFirstProcess(_ knowledge: URL, _ conversations: ConversationStore) async throws -> UUID {
        let first = try MecumProcess(knowledge: knowledge, bundle: bundle, window: routing,
                                     labels: ["All Busses", "Inputs", "Outputs"])
        var conversation = Conversation(provider: .claude, model: nil)
        conversation.append(.user, learning)
        let (start, end) = try await first.turn(learning) { tools, session in
            try await Self.openAndObserve(tools, session)
            try await Self.select(tools, session)
        }
        #expect(start.prompt == learning)
        #expect(end.report.decision.reason == .admittedSingleSelection)
        conversation.providerSessionID = "provider-session-of-the-first-chat"
        try conversations.save(conversation)
        await first.close()
        return conversation.id
    }

    // MARK: Tests

    @Test("a second instance over the directory and a new conversation receive the memory from disk only")
    @MainActor
    func secondProcessRecallsFromDisk() async throws {
        try await withDirectories { knowledge, conversations in
            let firstChat = try await learnInFirstProcess(knowledge, conversations)

            let second = try MecumProcess(knowledge: knowledge, bundle: bundle, window: routing,
                                          labels: ["All Busses", "Inputs", "Outputs"])
            let secondChat = Conversation(provider: .claude, model: nil)
            #expect(secondChat.id != firstChat)
            #expect(secondChat.entries.isEmpty)
            #expect(secondChat.providerSessionID == nil)
            let start = try await second.cycle.begin(recalling, sessionIsOpen: false)
            #expect(second.session.calls.isEmpty)
            let briefing = try #require(start.memory?.briefing)
            #expect(briefing.status == "suggested")
            #expect(briefing.match == "sameStep")
            #expect(briefing.currentEvidence == "notObserved")
            let remembered = try #require(briefing.remembered)
            #expect(remembered.originalRequest == learning)
            #expect(remembered.tool == "select")
            #expect(remembered.control == "All Busses")
            #expect(remembered.item == "Output Busses")
            #expect(briefing.contextLine
                    == "memory context: suggested select 'Output Busses' in 'All Busses' (verified ×1, notObserved)")
            #expect(briefing.contextLine?.contains("Optional") == false)
            #expect(remembered.application == bundle)
            #expect(remembered.window == "syntheticiosetup")
            #expect(remembered.lastVerifiedAt != nil)
            let invocation = try ProviderInvocation(ProviderTurn(
                provider: secondChat.provider, model: secondChat.model, sessionID: secondChat.providerSessionID,
                prompt: start.prompt, instructions: "Static.", bridgeExecutable: "/usr/bin/true",
                connectionFile: "/tmp/connection.json", workingDirectory: "/tmp"))
            #expect(!invocation.arguments.contains("--resume"))
            #expect(invocation.standardInput.hasPrefix("<mecum-memory>\n"))
            #expect(invocation.standardInput.hasSuffix("\n\n" + recalling))

            let record = try #require(try await second.store.experiences(in: [bundle]).first)
            #expect(record.step.arguments == ["control": "All Busses", "item": "Output Busses"])
            #expect(record.latestProof?.dropdown?.valueBefore == "All Busses")
            #expect(record.latestProof?.dropdown?.readback == .window("Output Busses"))
            #expect(record.context == WindowContext(bundleID: bundle, windowTitle: routing))
            #expect(!(try await second.store.sightings(in: [bundle])).isEmpty)

            // The same request against an empty knowledge directory has nothing to say.
            let empty = try MecumProcess(knowledge: knowledge.appendingPathComponent("Empty"), bundle: bundle,
                                         window: routing, labels: ["All Busses"])
            #expect(try await empty.cycle.begin(recalling, sessionIsOpen: false).memory?.briefing == nil)
            _ = await empty.cycle.end(.completed)

            try await Self.openAndObserve(second.tools, second.session)
            let seen = try await second.tools.call("observe", .object(["session": Self.id(second.session)]))
            #expect(seen["structuredContent"]["memory"]["currentEvidence"].string == "presentNow")
            try await Self.select(second.tools, second.session)
            let end = try #require(await second.cycle.end(.completed))
            guard case .recorded(_, .confirmsFollowedExperience)? = end.recording else {
                Issue.record("the second turn did not confirm the memory it followed"); return
            }
            let experiences = try await second.store.experiences(in: [bundle])
            #expect(experiences.count == 1)
            #expect(experiences.first?.successCount == 2)
            let inspection = await LivingMemoryReport.lines(bundleID: bundle, knowledgeDirectory: knowledge)
                .joined(separator: "\n")
            #expect(inspection.contains("request: \"\(learning)\""))
            #expect(inspection.contains("step: select 'Output Busses' in the control that read 'All Busses'"))
            #expect(inspection.contains("verified ×2, contradicted ×0"))
            #expect(inspection.contains("proof: 'All Busses' before, 'Output Busses' read in the window after"))
            #expect(inspection.contains("recall suggested"))
            #expect(!inspection.contains("555111999"))
            await second.close()
        }
    }

    @Test("another application or window, and an absent target, give no operational suggestion")
    @MainActor
    func otherContextsAndAbsentTarget() async throws {
        try await withDirectories { knowledge, conversations in
            _ = try await learnInFirstProcess(knowledge, conversations)
            let elsewhere = try MecumProcess(knowledge: knowledge, bundle: "test.synthetic.editor", window: routing,
                                             labels: ["All Busses"])
            _ = try await elsewhere.turn("Osserva la finestra") { tools, session in
                try await Self.openAndObserve(tools, session)
            }
            let otherApp = try await elsewhere.cycle.begin(recalling, sessionIsOpen: true)
            #expect(otherApp.memory?.briefing?.status == "refused")
            #expect(otherApp.memory?.briefing?.reason?.contains("otherApplication") == true)
            _ = await elsewhere.cycle.end(.completed)

            let mix = try MecumProcess(knowledge: knowledge, bundle: bundle, window: "Synthetic Mix",
                                       labels: ["All Busses"])
            let (_, _) = try await mix.turn(recalling) { tools, session in
                try await Self.openAndObserve(tools, session)
                let seen = try await tools.call("observe", .object(["session": Self.id(session)]))
                #expect(seen["structuredContent"]["memory"]["status"].string == "historical")
                #expect(seen["structuredContent"]["memory"]["reason"].string?.contains("otherWindow") == true)
            }

            let absent = try MecumProcess(knowledge: knowledge, bundle: bundle, window: routing, labels: ["Inputs"])
            let (_, end) = try await absent.turn(recalling) { tools, session in
                try await Self.openAndObserve(tools, session)
                let seen = try await tools.call("observe", .object(["session": Self.id(session)]))
                #expect(seen["structuredContent"]["memory"]["currentEvidence"].string == "absentNow")
            }
            #expect(end.report.decision.reason == .noSelection)
            let record = try #require(try await absent.store.experiences(in: [bundle]).first)
            #expect(record.failureCount == 0)
            #expect(absent.session.calls.filter { $0 == "select" }.isEmpty)
        }
    }

    @Test("an error, an interruption or an unchanged value adds no success, and a correction persists")
    @MainActor
    func failuresAndCorrection() async throws {
        try await withDirectories { knowledge, conversations in
            _ = try await learnInFirstProcess(knowledge, conversations)
            let process = try MecumProcess(knowledge: knowledge, bundle: bundle, window: routing,
                                           labels: ["All Busses", "Inputs"])
            let (_, failed) = try await process.turn(recalling) { tools, session in
                try await Self.openAndObserve(tools, session)
                try await Self.select(tools, session)
                session.observeFails = true
                _ = try? await tools.call("observe", .object(["session": Self.id(session)]))
                session.observeFails = false
            }
            #expect(failed.report.decision.reason == .toolFailed)
            process.session.labels = ["All Busses", "Inputs"]
            let (_, interrupted) = try await process.turn(recalling, ending: .interrupted) { tools, session in
                try await Self.select(tools, session)
            }
            #expect(interrupted.report.decision.reason == .turnInterrupted)
            let (_, unchanged) = try await process.turn(recalling) { tools, session in
                try await tools.call("select", .object(["session": Self.id(session),
                                                        "control": .string("Output Busses"),
                                                        "item": .string("Output Busses")]))
            }
            #expect(unchanged.report.decision.reason == .alreadySet)
            #expect(try await process.store.experiences(in: [bundle]).first?.successCount == 1)

            process.session.labels = ["All Busses", "Inputs"]
            process.session.valueAfterSelect = "All Busses"
            let (start, corrected) = try await process.turn(recalling) { tools, session in
                try await Self.select(tools, session)
            }
            #expect(start.memory?.followed != nil)
            #expect(corrected.report.decision.reason == .contradictsFollowedExperience)
            await process.close()

            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            let reopened = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            let record = try #require(try await reopened.experiences(in: [bundle]).first)
            #expect(record.successCount == 1)
            #expect(record.failureCount == 1)
            // The error, interruption and no-op turns stay unlinked history; only the correction is linked.
            #expect(try await reopened.history(of: record.id).count == 2)
            let inspection = await LivingMemoryReport.lines(bundleID: bundle, knowledgeDirectory: knowledge)
                .joined(separator: "\n")
            #expect(inspection.contains("verified ×1, contradicted ×1"))
            #expect(inspection.contains("contradicted (read 'All Busses')"))
        }
    }

    @Test("an unreliable memory, persisted by a correction, is refused by the next instance")
    @MainActor
    func unreliableAfterReopening() async throws {
        try await withDirectories { knowledge, conversations in
            _ = try await learnInFirstProcess(knowledge, conversations)
            do {
                let process = try MecumProcess(knowledge: knowledge, bundle: bundle, window: routing,
                                               labels: ["All Busses"])
                process.session.valueAfterSelect = "All Busses"
                let (_, corrected) = try await process.turn(recalling) { tools, session in
                    try await Self.openAndObserve(tools, session)
                    try await Self.select(tools, session)
                }
                #expect(corrected.report.decision.reason == .contradictsFollowedExperience)
                await process.close()
            }
            let next = try MecumProcess(knowledge: knowledge, bundle: bundle, window: routing, labels: ["All Busses"])
            let start = try await next.cycle.begin(recalling, sessionIsOpen: false)
            #expect(start.memory?.briefing?.status == "refused")
            #expect(start.memory?.briefing?.reason == "notReliable(successes: 1, failures: 1)")
            #expect(start.memory?.followed == nil)
            #expect(next.session.calls.isEmpty)
        }
    }
}

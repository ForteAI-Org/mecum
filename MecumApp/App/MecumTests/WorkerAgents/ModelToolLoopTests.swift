//
//  ModelToolLoopTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
@testable import ModelTransports
import PerceptionCore
import Synchronization
import Testing
@testable import Mecum

private let usage = ModelUsage(
    inputTokens : nil,
    outputTokens: nil,
    duration    : .zero
)

private let statusCall = ToolCall(
    id       : "call_0",
    name     : "status",
    arguments: Data("{}".utf8)
)

private let openFinder = ToolCall(
    id       : "call_0",
    name     : "open_session",
    arguments: Data(#"{"app":"Finder"}"#.utf8)
)

private let ollama = ModelSelection(
    provider: .ollama,
    model   : "qwen3:8b",
    effort  : .high
)

/// A transport that answers each round from its script and keeps what it was
/// sent. A round past the end of the script is held open, as a model still
/// generating is, until the stream is cancelled.
private final class ScriptedTransport: ModelTransport {

    struct Sent: Sendable {
        let messages: [TurnMessage]
        let tools   : [ToolDefinition]
    }

    private struct State {
        var rounds      : [[TurnEvent]]
        var sent        : [Sent] = []
        var held        : AsyncThrowingStream<TurnEvent, any Error>.Continuation?
        var wasCancelled = false
    }

    private let supportsTools: Bool
    private let state        : Mutex<State>

    init(
        supportsTools: Bool,
        rounds       : [[TurnEvent]]
    ) {
        self.supportsTools = supportsTools
        self.state         = Mutex(State(rounds: rounds))
    }

    var streaming: StreamingSupport { .incremental }

    var sent: [Sent] { state.withLock { $0.sent } }

    var wasCancelled: Bool { state.withLock { $0.wasCancelled } }

    func complete(
        prompt : String,
        schema : Data,
        timeout: TimeInterval
    ) async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("a scripted transport has no structured request")
    }

    func capabilities() async throws -> ModelCapabilities {
        ModelCapabilities(supportsTools: supportsTools)
    }

    func converse(
        _ messages: [TurnMessage],
        tools     : [ToolDefinition],
        timeout   : TimeInterval
    ) throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let events = state.withLock { state -> [TurnEvent]? in
            state.sent.append(Sent(
                messages: messages,
                tools   : tools
            ))
            return state.rounds.isEmpty ? nil : state.rounds.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            guard let events else {
                continuation.onTermination = { _ in self.state.withLock { $0.wasCancelled = true } }
                state.withLock { $0.held = continuation }
                return
            }
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// A desktop session that records its calls, and whose `open` waits until the
/// test lets it finish, so a stop can land while a tool call is in flight.
@MainActor
private final class RecordingSession: AutomationSessionOperating {

    let id: UUID? = nil

    private(set) var log: [String] = []

    private var opening: CheckedContinuation<Void, Never>?

    var isOpening: Bool { opening != nil }

    func open(
        application: String,
        window     : String?
    ) async throws -> SceneSnapshot {
        log.append("open")
        await withCheckedContinuation { opening = $0 }
        log.append("opened")
        throw AutomationFailure("Nothing opened.")
    }

    func finishOpening() {
        opening?.resume()
        opening = nil
    }

    func observe() async throws -> SceneSnapshot {
        throw AutomationFailure("No app is open.")
    }

    func act(
        target      : String,
        verb        : ActionVerb,
        section     : String?,
        desiredState: ControlState?
    ) async throws -> ActOutcome {
        throw AutomationFailure("No app is open.")
    }

    func select(
        control: String,
        item   : String
    ) async throws -> ActOutcome {
        throw AutomationFailure("No app is open.")
    }

    func deliver(
        _ input: InputRequest.Input,
        section: String?
    ) async throws -> ActOutcome {
        throw AutomationFailure("No app is open.")
    }

    func close() async {
        log.append("close")
    }
}

@MainActor
@Suite("Mecum's own loop over a model provider")
struct ModelToolLoopTests {

    @Test func aToolRoundThenAnAnswerReportsTheRecordsOneBlockAndTheEnd() async throws {
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : [
                [.toolCall(statusCall), .completed(usage)],
                [.delta("All "), .delta("good."), .completed(usage)],
            ]
        )
        let tools  = AutomationTools(session: DesktopUnavailableSession())
        var events = [WorkerAgentEvent]()
        tools.record = { events.append(.tool($0)) }
        let history = [
            TurnMessage(
                role: .user,
                text: "Earlier"
            ),
            TurnMessage(
                role: .assistant,
                text: "Noted"
            ),
        ]

        try await ModelToolLoop { try await tools.call($0, $1) }.run(
            transport: transport,
            role     : "Be brief.",
            history  : history,
            prompt   : "Is all well?"
        ) { events.append($0) }

        #expect(events.count == 4)
        #expect(events.first == .tool("→ status {}"))
        if case .tool(let record) = events[1] {
            #expect(record.hasPrefix("← status "))
        } else {
            Issue.record("The tool's result was not recorded second.")
        }
        #expect(Array(events.suffix(2)) == [.provider(.assistant("All good.")), .provider(.completed)])

        let sent = transport.sent
        #expect(sent.count == 2)
        #expect(sent.first?.tools.map(\.name) == AutomationTools.definitions.compactMap { $0["name"].string })
        #expect(sent.first?.messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(sent.first?.messages.first?.text == WorkerAgentHost.instructions(role: "Be brief."))
        #expect(sent.first?.messages.last?.text == "Is all well?")

        // The second round carries the call and its answer, as the MCP path's text.
        let asked    = try #require(sent.last?.messages.dropLast().last)
        let answered = try #require(sent.last?.messages.last)
        #expect(asked.role == .assistant)
        #expect(asked.toolCalls == [statusCall])
        #expect(answered.role == .tool)
        #expect(answered.call == statusCall)
        #expect(!answered.isError)
        #expect(answered.text.contains(#""permissions""#))
    }

    @Test func theRoundsRecordGoesBackOnTheAssistantMessageThatMadeTheCalls() async throws {
        let record = TurnRecord(
            provider: .anthropic,
            blocks  : [Data(#"{"signature":"EqQB","thinking":"","type":"thinking"}"#.utf8)]
        )
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : [
                [.toolCall(statusCall), .record(record), .completed(usage)],
                [.delta("Done."), .completed(usage)],
            ]
        )

        try await ModelToolLoop { _, _ in MCPRouter.toolResult(.object([:])) }.run(
            transport: transport,
            role     : nil,
            history  : [],
            prompt   : "Check."
        ) { _ in }

        let asked = try #require(transport.sent.last?.messages.dropLast().last)
        #expect(asked.role == .assistant)
        #expect(asked.toolCalls == [statusCall])
        #expect(asked.record == record)
    }

    @Test func aModelWithoutToolsIsSentNoneAndToldSo() async throws {
        let transport = ScriptedTransport(
            supportsTools: false,
            rounds       : [[.delta("Ciao."), .completed(usage)]]
        )
        var events = [WorkerAgentEvent]()

        try await ModelToolLoop { _, _ in
            Issue.record("A model without tools ran one.")
            return .null
        }.run(
            transport: transport,
            role     : "Answer in Italian.",
            history  : [],
            prompt   : "Hello"
        ) { events.append($0) }

        #expect(events == [.provider(.assistant("Ciao.")), .provider(.completed)])
        let sent         = try #require(transport.sent.first)
        let instructions = try #require(sent.messages.first?.text)
        #expect(sent.tools.isEmpty)
        #expect(instructions == WorkerAgentHost.textOnlyInstructions + "\n\nYour role:\nAnswer in Italian.")
        for name in AutomationTools.definitions.compactMap({ $0["name"].string }) where name.count > 6 {
            #expect(!instructions.contains(name))
        }
    }

    @Test func aToolThatThrowsAnswersTheModelWithTheErrorAndTheTurnGoesOn() async throws {
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : [
                [.toolCall(openFinder), .completed(usage)],
                [.delta("I can’t open apps here."), .completed(usage)],
            ]
        )
        let tools  = AutomationTools(session: DesktopUnavailableSession())
        var events = [WorkerAgentEvent]()
        tools.record = { events.append(.tool($0)) }

        try await ModelToolLoop { try await tools.call($0, $1) }.run(
            transport: transport,
            role     : nil,
            history  : [],
            prompt   : "Open Finder."
        ) { events.append($0) }

        #expect(events.first == .tool(#"→ open_session {"app":"Finder"}"#))
        #expect(events.last == .provider(.completed))

        let answered = try #require(transport.sent.last?.messages.last)
        let expected = MCPRouter.failureResult(AutomationFailure(DesktopUnavailableSession.refusal))
        #expect(answered.role == .tool)
        #expect(answered.isError)
        // Compared as JSON, since an object's keys come out in no fixed order.
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(answered.text.utf8)
        )
        #expect(decoded == expected["structuredContent"])
        #expect(answered.text.contains(#""status":"error""#))
    }

    @Test func theRoundsCostIsAddedUpTheLastRoundIsTheContextAndOllamasWindowIsItsSetting() async throws {
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : [
                [
                    .toolCall(statusCall),
                    .completed(ModelUsage(
                        inputTokens : 1000,
                        outputTokens: 20,
                        duration    : .zero
                    )),
                ],
                [
                    .delta("All good."),
                    .completed(ModelUsage(
                        inputTokens     : 100,
                        outputTokens    : 30,
                        duration        : .zero,
                        cacheReadTokens : 900,
                        cacheWriteTokens: 50
                    )),
                ],
            ]
        )
        let host = WorkerAgentHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { DesktopUnavailableSession() },
            agents          : { _ in throw AutomationFailure("A loop turn asked for a command line.") },
            transports      : { _ in transport },
            contextWindows  : {
                ModelToolLoop.contextWindow(
                    of       : $0,
                    settings : ProviderSettings(ollamaContextTokens: 16_384),
                    catalogue: []
                )
            }
        )
        var events = [WorkerAgentEvent]()

        try await host.run(
            prompt   : "Is all well?",
            selection: ollama,
            sessionID: nil,
            role     : nil
        ) { events.append($0) }

        guard case .usage(let usage)? = events.last else {
            Issue.record("The turn's usage did not come last.")
            return
        }
        #expect(events.dropLast().last == .provider(.completed))
        #expect(usage.turn == ProviderUsage.Tokens(
            input      : 1000 + 100 + 900 + 50,
            cacheReads : 900,
            cacheWrites: 50,
            output     : 50
        ))
        #expect(usage.contextTokens == 100 + 900 + 50 + 30)
        #expect(usage.contextWindow == 16_384)
        #expect(usage.provider == .ollama)
        #expect(usage.model == "qwen3:8b")
        #expect(usage.session == nil && usage.sessionTotal == nil && usage.rateLimits.isEmpty)
    }

    @Test func aModelOutsideOllamaTakesItsWindowFromTheCatalogue() {
        let gemini = ModelSelection(
            provider: .gemini,
            model   : "gemini-3-pro",
            effort  : .high
        )
        let listed = [ModelInfo(
            id           : "gemini-3-pro",
            efforts      : [.low, .high],
            contextWindow: 1_048_576
        )]
        #expect(ModelToolLoop.contextWindow(
            of       : gemini,
            settings : ProviderSettings(),
            catalogue: listed
        ) == 1_048_576)
        #expect(ModelToolLoop.contextWindow(
            of       : gemini,
            settings : ProviderSettings(),
            catalogue: []
        ) == nil)
    }

    @Test func aStopDuringARoundCancelsTheStreamAndClosesTheSession() async throws {
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : []
        )
        let session = RecordingSession()
        let host    = WorkerAgentHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { session },
            agents          : { _ in throw AutomationFailure("A loop turn asked for a command line.") },
            transports      : { _ in transport }
        )
        var events = [WorkerAgentEvent]()
        let turn   = Task {
            try await host.run(
                prompt   : "Wait.",
                selection: ollama,
                sessionID: "ignored",
                role     : nil
            ) { events.append($0) }
        }

        try await Self.wait { transport.sent.count == 1 }
        host.stop()

        await #expect(throws: CancellationError.self) { try await turn.value }
        #expect(transport.wasCancelled)
        #expect(session.log == ["close"])
        #expect(!events.contains(.provider(.completed)))
        #expect(!events.contains { if case .provider(.session(_)) = $0 { true } else { false } })
        #expect(!host.isRunning)
    }

    @Test func aStopWhileAToolRunsLetsItFinishAndStartsNoOther() async throws {
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : [[.toolCall(openFinder), .toolCall(statusCall), .completed(usage)]]
        )
        let session = RecordingSession()
        let host    = WorkerAgentHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { session },
            agents          : { _ in throw AutomationFailure("A loop turn asked for a command line.") },
            transports      : { _ in transport }
        )
        var events = [WorkerAgentEvent]()
        let turn   = Task {
            try await host.run(
                prompt   : "Open Finder.",
                selection: ollama,
                sessionID: nil,
                role     : nil
            ) { events.append($0) }
        }

        try await Self.wait { session.isOpening }
        host.stop()
        session.finishOpening()

        await #expect(throws: CancellationError.self) { try await turn.value }
        #expect(session.log == ["open", "opened", "close"])
        #expect(!events.contains(.tool("→ status {}")))
        #expect(transport.sent.count == 1)
    }

    /// Quitting closes the host while a tool call runs. The closing task is cancelled
    /// too, so a wait that gave up on cancellation would spin on the main actor.
    @Test func closingDuringAToolCallWaitsForItThenClosesTheSession() async throws {
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : [[.toolCall(openFinder), .toolCall(statusCall), .completed(usage)]]
        )
        let session = RecordingSession()
        let host    = WorkerAgentHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { session },
            agents          : { _ in throw AutomationFailure("A loop turn asked for a command line.") },
            transports      : { _ in transport }
        )
        var events = [WorkerAgentEvent]()
        let turn   = Task {
            try await host.run(
                prompt   : "Open Finder.",
                selection: ollama,
                sessionID: nil,
                role     : nil
            ) { events.append($0) }
        }
        try await Self.wait { session.isOpening }

        var isClosed = false
        let closing  = Task {
            try await host.close()
            isClosed = true
        }
        closing.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!isClosed)
        #expect(session.log == ["open"])

        session.finishOpening()
        try await closing.value
        #expect(isClosed)
        #expect(session.log.starts(with: ["open", "opened", "close"]))
        await #expect(throws: CancellationError.self) { try await turn.value }
        #expect(!events.contains(.tool("→ status {}")))
        #expect(!host.isRunning)
    }

    @Test func aModelThatKeepsCallingToolsIsStoppedAtTheCeiling() async throws {
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : Array(
                repeating: [.toolCall(statusCall), .completed(usage)],
                count    : ModelToolLoop.toolRoundLimit + 1
            )
        )
        var calls = 0

        let failure = await #expect(throws: AutomationFailure.self) {
            try await ModelToolLoop { _, _ in
                calls += 1
                return MCPRouter.toolResult(.object([:]))
            }.run(
                transport: transport,
                role     : nil,
                history  : [],
                prompt   : "Loop."
            ) { _ in }
        }
        #expect(failure?.description.contains("after \(ModelToolLoop.toolRoundLimit) rounds") == true)
        #expect(calls == ModelToolLoop.toolRoundLimit)
        #expect(transport.sent.count == ModelToolLoop.toolRoundLimit + 1)
    }

    @Test func theHistoryIsThePersonAndThisWorkerBeforeTheMessage() async throws {
        let root = URL.temporaryDirectory.appending(path: "mecum-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store        = try WorkspaceStore.opening(in: root)
        let worker       = UUID()
        let conversation = try await store.createConversation(participants: [worker]).id
        try await store.appendMessage(
            to  : conversation,
            text: "Open Finder."
        )
        try await store.appendMessage(
            to    : conversation,
            author: worker,
            text  : "Done."
        )
        try await store.appendMessage(
            to    : conversation,
            author: worker,
            text  : "  \n"
        )
        try await store.appendMessage(
            to    : conversation,
            author: UUID(),
            text  : "Someone else."
        )
        let current = try await store.appendMessage(
            to  : conversation,
            text: "And now?"
        )

        let earlier = try await store.messages(
            in    : conversation,
            around: current.sequence,
            before: 40,
            after : 0
        )
        let history = TeamModel.turnHistory(
            earlier,
            by: worker
        )
        #expect(history == [
            TurnMessage(
                role: .user,
                text: "Open Finder."
            ),
            TurnMessage(
                role: .assistant,
                text: "Done."
            ),
        ])
    }

    /// Waits for `condition`, a few seconds at most.
    private static func wait(for condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

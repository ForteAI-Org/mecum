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
import SQLite3
import SQLiteMemory
import Synchronization
import Testing
@testable import AgentTurn

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
        window     : String?,
        context    : ActionContext
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

    func observe(context: ActionContext) async throws -> SceneSnapshot {
        throw AutomationFailure("No app is open.")
    }

    func act(
        target      : String,
        verb        : ActionVerb,
        section     : String?,
        desiredState: ControlState?,
        context     : ActionContext
    ) async throws -> ActOutcome {
        throw AutomationFailure("No app is open.")
    }

    func select(
        control: String,
        item   : String,
        context: ActionContext
    ) async throws -> ActOutcome {
        throw AutomationFailure("No app is open.")
    }

    func deliver(
        _ input: InputRequest.Input,
        section: String?,
        context: ActionContext
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
        var events = [AgentTurnEvent]()
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
        #expect(sent.first?.messages.first?.text == AgentTurnHost.instructions(role: "Be brief."))
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
        var events = [AgentTurnEvent]()

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
        #expect(instructions == AgentTurnHost.textOnlyInstructions + "\n\nYour role:\nAnswer in Italian.")
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
        var events = [AgentTurnEvent]()
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
        let host = AgentTurnHost(
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
        var events = [AgentTurnEvent]()

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
        let host    = AgentTurnHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { session },
            agents          : { _ in throw AutomationFailure("A loop turn asked for a command line.") },
            transports      : { _ in transport }
        )
        var events = [AgentTurnEvent]()
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
        let host    = AgentTurnHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { session },
            agents          : { _ in throw AutomationFailure("A loop turn asked for a command line.") },
            transports      : { _ in transport }
        )
        var events = [AgentTurnEvent]()
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
        let host    = AgentTurnHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { session },
            agents          : { _ in throw AutomationFailure("A loop turn asked for a command line.") },
            transports      : { _ in transport }
        )
        var events = [AgentTurnEvent]()
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

    // MARK: Compaction

    @Test func aCompactionThroughTheLoopIsOneSummaryCallWithNoTools() async throws {
        let transport = ScriptedTransport(
            supportsTools: true,
            rounds       : [[
                .delta("Goals: ship the build. "),
                .delta("Open: the width assertion."),
                .completed(ModelUsage(
                    inputTokens : 3000,
                    outputTokens: 200,
                    duration    : .zero
                )),
            ]]
        )
        let host      = AgentTurnHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { DesktopUnavailableSession() },
            agents          : { _ in throw AutomationFailure("A loop compaction asked for a command line.") },
            transports      : { _ in transport },
            contextWindows  : { _ in 16_384 }
        )
        let history   = [
            TurnMessage(
                role: .user,
                text: "Earlier"
            ),
            TurnMessage(
                role: .assistant,
                text: "Noted"
            ),
        ]

        let done = try await host.compact(
            selection: ollama,
            sessionID: nil,
            role     : "Be brief.",
            trigger  : .automatic,
            history  : history
        )

        #expect(done.compaction == ContextCompaction(
            provider     : .ollama,
            trigger      : .automatic,
            preTokens    : 3000,
            postTokens   : 200,
            contextWindow: 16_384,
            summary      : "Goals: ship the build. Open: the width assertion."
        ))
        let usage = try #require(done.usage)
        #expect(usage.turn == ProviderUsage.Tokens(
            input : 3000,
            output: 200
        ))
        #expect(usage.contextTokens == nil, "the summary call's own size is not the context after it")

        let sent = try #require(transport.sent.first)
        #expect(transport.sent.count == 1)
        #expect(sent.tools.isEmpty)
        #expect(sent.messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(sent.messages.first?.text == ModelToolLoop.summaryInstructions)
        #expect(sent.messages.last?.text == ModelToolLoop.summaryRequest)
        #expect(!host.isRunning)
    }

    @Test func aStopDuringTheSummaryEndsTheCompaction() async throws {
        let transport = ScriptedTransport(
            supportsTools: false,
            rounds       : []
        )
        let host      = AgentTurnHost(
            workingDirectory: URL.temporaryDirectory.appending(path: "mecum-loop-\(UUID().uuidString)"),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { DesktopUnavailableSession() },
            agents          : { _ in throw AutomationFailure("A loop compaction asked for a command line.") },
            transports      : { _ in transport }
        )
        let compaction = Task {
            try await host.compact(
                selection: ollama,
                sessionID: nil,
                role     : nil,
                trigger  : .manual
            )
        }

        try await Self.wait { transport.sent.count == 1 }
        host.stop()

        await #expect(throws: CancellationError.self) { _ = try await compaction.value }
        #expect(transport.wasCancelled)
        #expect(!host.isRunning)
    }

    /// Waits for `condition`, a few seconds at most.
    private static func wait(for condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

// The supervision's probe of the S4 stop correction (verifiche-s4-stop-servizio-codex), carried in
// with its requirements unchanged: SQLite3 and SQLiteMemory are imported above for it alone.
extension ModelToolLoopTests {
    @Test("A stopped model-loop owner bounds memory finalization without cancelling the UI call", arguments: [false, true])
    func supervisionStoppedLoopBoundsMemory(stopBeforeFinalization: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: "mecum-supervision-loop-stop-\(UUID().uuidString)/Knowledge")
        let memory = MemoryService(directory: directory, configuration: .init(
            store: .init(lockBudget: .milliseconds(20), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(5)),
            finalizationBudget: .milliseconds(100)
        ))
        try await memory.open()
        let transport = ScriptedTransport(supportsTools: true,
            rounds: [[.toolCall(openFinder), .toolCall(statusCall), .completed(usage)]])
        let session = RecordingSession()
        let host = AgentTurnHost(workingDirectory: directory.deletingLastPathComponent(),
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"), session: { session },
            agents: { _ in throw AutomationFailure("No authentic provider is used.") },
            transports: { _ in transport }, memory: memory)
        let turn = Task {
            try await host.run(prompt: "Open Finder.", selection: ollama, sessionID: nil, role: nil) { _ in }
        }
        try await Self.wait { session.isOpening }
        var handle: OpaquePointer?
        try #require(sqlite3_open(memory.url.path, &handle) == SQLITE_OK)
        try #require(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        if stopBeforeFinalization { host.stop() }
        session.finishOpening()
        if !stopBeforeFinalization {
            let until = ContinuousClock.now + .seconds(2)
            while (await memory.status().diagnostics?.retainedWrites ?? 0) == 0, ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(2))
            }
            try #require((await memory.status().diagnostics?.retainedWrites ?? 0) == 1)
            host.stop()
        }
        // Wait well beyond the 100 ms memory budget. The lock is always released below,
        // so the probe completes even on the defective implementation.
        try await Task.sleep(for: .milliseconds(400))
        let stillWaiting = (await memory.status().diagnostics?.retainedWrites ?? 0) == 1
        let stillRunning = host.isRunning
        print("SUPERVISION-LOOP-STOP beforeFinalization=\(stopBeforeFinalization) "
            + "hostRunning=\(stillRunning) retainedWrite=\(stillWaiting) callerCancelled=\(turn.isCancelled)")
        #expect(!stillRunning, "The stopped owner must finish memory finalization within its budget; the physical call was already completed.")
        #expect(!stillWaiting, "No memory finalization may remain waiting beyond the stopped owner's deadline.")
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        await #expect(throws: CancellationError.self) { try await turn.value }
        try await host.close()
        await memory.close()
    }
}

/// The stop of Mecum's own loop, which lets a tool call in flight finish its action, reaches what that
/// call still has to write in the memory: the turn's owner is stopped by the host, and the call's
/// finalization, whose task is not cancelled, ends at the owner's deadline. The UI call is never cut
/// short or run twice; what the memory could not keep is said. A scripted transport and session, the
/// real tools and service on a temporary archive, another connection holding the lock.
extension ModelToolLoopTests {

    private static let loopBudget = Duration.milliseconds(150)

    private struct StoppedLoop {
        let memory: MemoryService
        let session: RecordingSession
        let transport: ScriptedTransport
        let host: AgentTurnHost
        let turn: Task<Void, any Error>
        let events: () -> [AgentTurnEvent]
        let lock: OpaquePointer
    }

    /// A loop turn whose `open_session` waits in the session, with the archive's lock taken after the
    /// call was planned and started, so only the call's end is left to write.
    /// `configuration` replaces the short budget of these rows, for the production measure.
    private func stoppedLoop(configuration: MemoryService.Configuration? = nil) async throws -> StoppedLoop {
        let directory = URL.temporaryDirectory.appending(path: "mecum-loop-stop-\(UUID().uuidString)/Knowledge")
        let memory = MemoryService(directory: directory, configuration: configuration ?? .init(
            store: .init(lockBudget: .milliseconds(20), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(5)),
            finalizationBudget: Self.loopBudget
        ))
        try await memory.open()
        let transport = ScriptedTransport(supportsTools: true,
                                          rounds: [[.toolCall(openFinder), .toolCall(statusCall), .completed(usage)]])
        let session = RecordingSession()
        let host = AgentTurnHost(workingDirectory: directory.deletingLastPathComponent(),
                                 bridgeExecutable: URL(fileURLWithPath: "/nonexistent"), session: { session },
                                 agents: { _ in throw AutomationFailure("No authentic provider is used.") },
                                 transports: { _ in transport }, memory: memory)
        var events = [AgentTurnEvent]()
        let turn = Task {
            try await host.run(prompt: "Open Finder.", selection: ollama, sessionID: nil, role: nil) { events.append($0) }
        }
        try await Self.wait { session.isOpening }
        var handle: OpaquePointer?
        try #require(sqlite3_open(memory.url.path, &handle) == SQLITE_OK)
        let lock = try #require(handle)
        try #require(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        return StoppedLoop(memory: memory, session: session, transport: transport, host: host, turn: turn,
                           events: { events }, lock: lock)
    }

    private func gaps(_ events: [AgentTurnEvent]) -> [String] {
        events.compactMap { if case .tool(let line) = $0, line.hasPrefix("← memory") { line } else { nil } }
    }

    @Test("a stopped loop turn keeps its UI call whole and bounds its memory: the call completes once, no tool follows, the session closes, the gap is said",
          arguments: [false, true])
    func aStoppedLoopKeepsTheCallAndBoundsTheMemory(stopBeforeFinalization: Bool) async throws {
        let made = try await stoppedLoop()
        defer { sqlite3_close(made.lock) }
        let stop = ContinuousClock.now
        if stopBeforeFinalization { made.host.stop() }
        made.session.finishOpening()
        if !stopBeforeFinalization {
            try await Self.wait { made.session.log.contains("opened") }
            made.host.stop()
        }
        await #expect(throws: CancellationError.self) { try await made.turn.value }
        let elapsed = ContinuousClock.now - stop
        sqlite3_exec(made.lock, "ROLLBACK", nil, nil, nil)
        #expect(made.session.log == ["open", "opened", "close"], "the action ran once and the session was closed")
        #expect(!made.events().contains(.tool("→ status {}")), "no tool after the stop")
        #expect(made.transport.sent.count == 1, "the model was not asked again")
        #expect(gaps(made.events()).count == 1, "the call's end the memory could not keep, said: \(gaps(made.events()))")
        #expect(elapsed < .seconds(2), "the memory's wait ended at the owner's deadline, not at the lock's release")
        #expect(await made.memory.status().diagnostics?.retainedWrites == 0, "no write left waiting")
        #expect(!made.host.isRunning)
        try await made.host.close()
        await made.memory.close()
    }

    @Test("closing the loop host during a tool call waits for the call, bounds its memory by the same budget, and closes the session")
    func closingTheLoopHostBoundsTheMemory() async throws {
        let made = try await stoppedLoop()
        defer { sqlite3_close(made.lock) }
        let closing = Task { try await made.host.close() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(made.session.log == ["open"], "the call in flight is not cut short by the close")
        made.session.finishOpening()
        try await closing.value
        sqlite3_exec(made.lock, "ROLLBACK", nil, nil, nil)
        #expect(made.session.log.starts(with: ["open", "opened", "close"]))
        await #expect(throws: CancellationError.self) { try await made.turn.value }
        #expect(!made.events().contains(.tool("→ status {}")))
        #expect(gaps(made.events()).count == 1)
        #expect(await made.memory.status().diagnostics?.retainedWrites == 0)
        await made.memory.close()
    }

    @Test("a lock released within what is left of the budget: the stopped loop's call end is saved once, nothing replayed")
    func aReleaseWithinTheBudgetSavesTheLoopsCall() async throws {
        let made = try await stoppedLoop()
        defer { sqlite3_close(made.lock) }
        let before = await made.memory.status().diagnostics?.commits ?? -1
        made.host.stop()
        made.session.finishOpening()
        try await Task.sleep(for: Self.loopBudget / 3)
        sqlite3_exec(made.lock, "ROLLBACK", nil, nil, nil)
        await #expect(throws: CancellationError.self) { try await made.turn.value }
        #expect(made.session.log == ["open", "opened", "close"])
        #expect(gaps(made.events()).isEmpty, "\(gaps(made.events()))")
        #expect(await made.memory.status().diagnostics?.commits == before + 1, "the call's end, written once")
        try await made.host.close()
        await made.memory.close()
    }
}

/// The stop of Mecum's own loop measured with the memory's production defaults (a 3 s budget, the store's
/// own lock cycles): the turn's task is not cancelled, the host stops the turn's owner while the call's end
/// waits on a real lock taken after the call was planned and started. Prints one `BUDGET-MEASURE` line.
/// Enabled with `MECUM_MEASURE_PRODUCTION=1` only.
extension ModelToolLoopTests {
    @Test("measured, production budget: a stopped loop's call end, waiting on a held lock, is cut after one budget; the caller is not cancelled",
          .enabled(if: ProcessInfo.processInfo.environment["MECUM_MEASURE_PRODUCTION"] == "1",
                   "MECUM_MEASURE_PRODUCTION=1 runs the production budget"))
    func productionBudgetBoundsTheStoppedLoop() async throws {
        let budget = MemoryService.Configuration().finalizationBudget
        let made = try await stoppedLoop(configuration: MemoryService.Configuration())
        defer { sqlite3_close(made.lock) }
        made.session.finishOpening()
        try await Self.wait { made.session.log.contains("opened") }
        let until = ContinuousClock.now + .seconds(10)
        while (await made.memory.status().diagnostics?.retainedWrites ?? 0) == 0, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        let waiting = (await made.memory.status().diagnostics?.retainedWrites ?? 0) == 1
        let stop = ContinuousClock.now
        made.host.stop()
        await #expect(throws: CancellationError.self) { try await made.turn.value }
        let elapsed = ContinuousClock.now - stop
        let callerCancelled = made.turn.isCancelled
        let retained = await made.memory.status().diagnostics?.retainedWrites
        sqlite3_exec(made.lock, "ROLLBACK", nil, nil, nil)
        let elapsedMS = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let budgetMS = budget.components.seconds * 1000
        print("BUDGET-MEASURE case=inner-loop-stop budgetMs=\(budgetMS) waitingBeforeStop=\(waiting) stopToTurnEndMs=\(elapsedMS) "
              + "callerCancelled=\(callerCancelled) gaps=\(gaps(made.events()).count) retained=\(retained.map(String.init) ?? "-") "
              + "session=\(made.session.log) modelRequests=\(made.transport.sent.count)")
        #expect(waiting, "the call's end was waiting on the lock before the stop")
        #expect(!callerCancelled, "the turn's task was not cancelled: the host stopped its owner")
        #expect(elapsed >= budget && elapsed < budget * 2, "one budget from the stop")
        #expect(gaps(made.events()).count == 1, "the call's end the memory could not keep, said")
        #expect(retained == 0)
        #expect(made.session.log == ["open", "opened", "close"], "the action ran once and the session was closed")
        #expect(made.transport.sent.count == 1, "the model was not asked again")
        try await made.host.close()
        await made.memory.close()
    }
}

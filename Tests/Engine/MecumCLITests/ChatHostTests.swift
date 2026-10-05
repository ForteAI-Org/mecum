//
//  ChatHostTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import AgentTurn
import AppKit
import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import EngineCore
import FileConversations
import Foundation
import ModelTransports
import Memory
import Network
import PerceptionCore
import SeatCore
import SeatDriving
import SQLite3
import Testing
@testable import LocalMCP
@testable import SeatBroker
@testable import mecum

/// The terminal chat's host over the broker's desktop and the turn core, driven as `ChatCommand` drives
/// it: with the queue's own seats, a session whose seating is supplied in place of macOS and raises no
/// display, and a provider stand-in that speaks to the core's loopback the way the real command line's
/// bridge does, so a turn crosses the connection file, the authenticated channel, the router and the 14
/// shared tools. What a real application does on a display, and the parity of a task between the app
/// and this chat, is live work (S4) and is not claimed here.
@MainActor
@Suite("The chat host over the broker's desktop", .serialized)
struct ChatHostTests {

    private static let workerID = UUID()
    private static let label    = workerID.uuidString

    /// A provider turn ends the way a child does when it is interrupted: with an error, not a result.
    private struct Interrupted: Error {}

    /// A provider's own failure, as a child that exits non-zero.
    private struct ProviderFailed: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Stands in for the idle window's clock, as the broker's own tests do: each wait is recorded and
    /// returns only when the test lets the oldest one elapse, so no test waits the window out.
    @MainActor
    private final class IdleClock {
        private(set) var waits: [Duration] = []
        private var pending: [CheckedContinuation<Void, Never>] = []

        var pendingCount: Int { pending.count }

        func wait(_ window: Duration) async {
            waits.append(window)
            await withCheckedContinuation { pending.append($0) }
        }

        func elapseOldest() async {
            await ChatHostTests.until { !self.pending.isEmpty }
            guard !pending.isEmpty else {
                Issue.record("no idle wait began")
                return
            }
            pending.removeFirst().resume()
        }
    }

    /// One step of a scripted provider turn. A call goes through the loopback like the bridge's; the
    /// session argument `$session` is the id the last observation answered with. `list` asks the
    /// loopback for its tools, `session` reports a provider session, `act` runs something in the test
    /// while the turn is under way.
    private enum Step {
        case call(String, [String: JSONValue])
        case list
        case say(String)
        case session(String)
        case act(@MainActor () -> Void)
        case waitUntilCancelled
        case fail(String)
        /// What the provider says the turn cost, and a compaction's boundary, as a command line reports them.
        case usage(ProviderUsage)
        case compacted(Int?, Int?)
    }

    /// A provider stand-in: it runs one script per turn against the core's loopback, read from the
    /// connection file the turn names, and records the turns it was given and the replies it got.
    /// `cancel` ends the turn at its next step, as SIGINT ends a child.
    @MainActor
    private final class ScriptedProvider: ProviderTurnRunning {
        var scripts: [[Step]] = []
        private(set) var turns  : [ProviderTurn] = []
        private(set) var replies: [[JSONValue]] = []
        private(set) var listed : [[String]] = []
        private(set) var ports  : [UInt16] = []
        private(set) var isWaiting = false
        private var isRunning   = false
        private var isCancelled = false
        private var waiter: CheckedContinuation<Void, Never>?
        /// The session the last observation answered with, kept across turns as a provider's context keeps it.
        private var session: String?

        func run(
            _ turn    : ProviderTurn,
            executable: URL,
            onStart   : @MainActor (ChildProcessIdentity) -> Void,
            onEvent   : @escaping @MainActor (ProviderEvent) throws -> Void
        ) async throws {
            turns.append(turn)
            isRunning   = true
            isCancelled = false
            defer { isRunning = false }
            let endpoint = try JSONDecoder().decode(LocalConnection.self,
                                                    from: Data(contentsOf: URL(fileURLWithPath: turn.connectionFile)))
            ports.append(endpoint.port)
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw Interrupted() }
            let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
            try await channel.start()
            defer { channel.close() }
            var got: [JSONValue] = []
            defer { replies.append(got) }
            let script = scripts.isEmpty ? [] : scripts.removeFirst()
            for (index, step) in script.enumerated() {
                switch step {
                case .call(let name, var arguments):
                    if arguments["session"] == .string("$session") { arguments["session"] = session.map { .string($0) } ?? .null }
                    try await channel.write(.object(["token": .string(endpoint.token), "message": .object([
                        "jsonrpc": .string("2.0"), "id": .number(Double(index + 1)), "method": .string("tools/call"),
                        "params" : .object(["name": .string(name), "arguments": .object(arguments)])
                    ])]))
                    guard let reply = try await channel.read() else { throw Interrupted() }
                    got.append(reply)
                    if let id = reply["result"]["structuredContent"]["session"].string { session = id }
                case .list:
                    try await channel.write(.object(["token": .string(endpoint.token), "message": .object([
                        "jsonrpc": .string("2.0"), "id": .number(Double(index + 1)), "method": .string("tools/list")
                    ])]))
                    guard let reply = try await channel.read() else { throw Interrupted() }
                    listed.append(reply["result"]["tools"].array?.compactMap { $0["name"].string } ?? [])
                case .say(let text):
                    try onEvent(.assistant(text))
                case .session(let id):
                    try onEvent(.session(id))
                case .act(let body):
                    body()
                case .waitUntilCancelled:
                    isWaiting = true
                    await withCheckedContinuation { waiter = $0 }
                    isWaiting = false
                    throw Interrupted()
                case .fail(let reason):
                    throw ProviderFailed(reason: reason)
                case .usage(let usage):
                    try onEvent(.usage(usage))
                case .compacted(let pre, let post):
                    try onEvent(.compacted(preTokens: pre, postTokens: post))
                }
                if isCancelled { throw Interrupted() }
            }
            try onEvent(.completed)
        }

        func cancel() {
            isCancelled = true
            waiter?.resume()
            waiter = nil
        }

        func waitUntilStopped() async {
            while isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    /// Everything a host is composed of in these tests, kept together so a test reads what it holds.
    private struct Composition {
        let broker  : SeatBroker
        let desktop : BrokeredAutomationSession
        let host    : ChatHost
        let provider: ScriptedProvider
        let idle    : IdleClock
        let scratch : URL
        let store   : ConversationStore
        let memory  : MemoryService
        let workerID: UUID
    }

    /// A broker whose seats never raise a display, and a desktop session over it whose seating names the
    /// Dock as the running application, which nothing adopts or quits, with the scene supplied in place
    /// of perception. `holding` is a pid the granted session holds as if adopted, so closing finishes with
    /// it as the ledger says; `granted` sees the seat the queue handed the open, and `opens` counts the openings.
    private static func desktop(
        in scratch: URL,
        ledger    : LaunchLedger = LaunchLedger(),
        holding   : pid_t? = nil,
        granted   : @escaping @MainActor (AgentSession) -> Void = { _ in },
        opens     : @escaping @MainActor () -> Void = {},
        memory    : MemoryService? = nil,
        workerID  : UUID = workerID,
        perceived : @escaping @MainActor () -> Void = {}
    ) throws -> (broker: SeatBroker, desktop: BrokeredAutomationSession, idle: IdleClock, memory: MemoryService) {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene = SceneSnapshot(bundleID: "com.apple.dock", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let broker  = SeatBroker(
            configuration: SeatBrokerConfiguration(
                recordingDirectory: scratch.appendingPathComponent("Runs", isDirectory: true)
            ),
            ledger: ledger
        )
        let idle    = IdleClock()
        let memory  = memory ?? MemoryService(directory: scratch.appendingPathComponent("Knowledge", isDirectory: true))
        let desktop = BrokeredAutomationSession(
            broker            : broker,
            workerID          : workerID,
            memory            : memory,
            allowsDestructive : false,
            missingGrant      : { nil },
            requestGrants     : {},
            seating           : { session, _, _ in
                opens()
                granted(session)
                if let holding { session.holdWithoutAdopting(holding, name: "Test") }
                return (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []),
                        SeatTarget())
            },
            perceiving        : { _, _ in
                perceived()
                return PerceivedWindow(scene: scene, frame: .zero)
            },
            waitIdle          : { await idle.wait($0) }
        )
        return (broker, desktop, idle, memory)
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-chat-host-\(UUID().uuidString)", isDirectory: true)
    }

    /// A chat host as `ChatCommand` composes one, over a controlled desktop and a scripted provider, with
    /// the invocation's turn configuration (`role`, `effort`, `webSearch`) and the conversation's
    /// command line and model. `resuming` composes a second host over an earlier one's store, scratch
    /// and saved conversation, as a later `mecum chat --resume` would.
    private static func compose(
        ledger     : LaunchLedger = LaunchLedger(),
        holding    : pid_t? = nil,
        commandLine: ChatProvider = .claude,
        model      : String? = nil,
        role       : String? = nil,
        effort     : ReasoningEffort? = nil,
        webSearch  : Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resuming   : Composition? = nil,
        granted    : @escaping @MainActor (AgentSession) -> Void = { _ in },
        opens      : @escaping @MainActor () -> Void = {},
        memory     : MemoryService? = nil,
        perceived  : @escaping @MainActor () -> Void = {}
    ) throws -> Composition {
        let scratch    = resuming?.scratch ?? scratch()
        let made       = try desktop(in: scratch, ledger: ledger, holding: holding, granted: granted, opens: opens,
                                     memory: resuming?.memory ?? memory, perceived: perceived)
        let store      = try resuming?.store ?? ConversationStore(directory: scratch.appendingPathComponent("Conversations"))
        var conversation = Conversation(provider: commandLine, model: model)
        if resuming != nil { conversation = try #require(try store.list().first) }
        let transcript = ChatTranscript(conversation: conversation, store: store)
        let provider   = ScriptedProvider()
        let host       = ChatHost(
            broker          : made.broker,
            desktop         : made.desktop,
            transcript      : transcript,
            memory          : made.memory,
            workerID        : Self.workerID,
            executable      : URL(fileURLWithPath: "/usr/bin/true"),
            bridgeExecutable: "/usr/bin/true",
            workingDirectory: scratch.appendingPathComponent("ProviderWorkspace", isDirectory: true),
            role            : role,
            effort          : effort,
            allowsWebSearch : webSearch,
            provider        : provider,
            environment     : environment
        )
        return Composition(broker: made.broker, desktop: made.desktop, host: host, provider: provider,
                           idle: made.idle, scratch: scratch, store: store, memory: made.memory, workerID: Self.workerID)
    }

    /// Waits, a few milliseconds at a time, until `condition` holds or a few seconds have passed.
    private static func until(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// `read` for a run: the lines in order, then the end of input. `before` runs ahead of each line,
    /// with its index, where a test needs to look at the host between two turns.
    private static func lines(
        _ lines: [String],
        before : @escaping @MainActor (Int) async -> Void = { _ in }
    ) -> @MainActor () async -> String? {
        var remaining = lines
        var index = 0
        return {
            guard !remaining.isEmpty else { return nil }
            await before(index)
            index += 1
            return remaining.removeFirst()
        }
    }

    private static let open: Step = .call("open_session", ["app": .string("Test")])
    private static let observe: Step = .call("observe", ["session": .string("$session")])

    private static func session(of reply: JSONValue) -> String? {
        reply["result"]["structuredContent"]["session"].string
    }

    private static func isError(_ reply: JSONValue) -> Bool {
        reply["result"]["isError"] == .bool(true)
    }

    /// The directory of the connection file the core wrote for `provider`'s first turn, which the
    /// core removes when it closes.
    private static func temporaryDirectory(of provider: ScriptedProvider) -> URL? {
        provider.turns.first.map { URL(fileURLWithPath: $0.connectionFile).deletingLastPathComponent() }
    }

    private static func exists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    @Test("the host's turns run over the core's tools, the fourteen shared ones over the broker's session",
          .timeLimit(.minutes(1)))
    func theToolsAreTheSharedOnesOverTheBrokersSession() async throws {
        let made = try Self.compose()
        #expect(made.host.agent.tools.session === made.desktop)
        #expect(made.host.broker === made.broker)
        #expect(made.host.desktop === made.desktop)
        #expect(ChatTools.definitions.count == 14)

        made.provider.scripts = [[.list, .say("ok")]]
        try await made.host.run(prompt: "list", interactive: false, once: true, read: { nil })

        #expect(made.provider.listed == [ChatTools.definitions.compactMap { $0["name"].string }])
        #expect(made.provider.listed.first?.count == 14)
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
        #expect(made.broker.queue.entries.isEmpty)
    }

    @Test("a turn's calls are recorded in the chat's memory from the cli source, the chat's worker as the stream and the conversation as the trace",
          .timeLimit(.minutes(1)))
    func theCallsAreRecordedInTheChatsMemory() async throws {
        let made = try Self.compose()
        made.provider.scripts = [[Self.open, Self.observe, .say("Opened Test.")]]
        try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil })
        #expect(await made.memory.status().state == .closed, "the host closes the memory last")

        // The archive outlives the host: a second service on the chat's directory reads what the turn recorded.
        let reader = MemoryService(directory: made.memory.directory)
        let trace  = try #require(try made.store.list().first?.id.uuidString)
        let calls  = try await reader.calls(inTrace: trace, after: nil, limit: 10)
        #expect(calls.map(\.request.tool) == [.openSession, .observe])
        #expect(calls.allSatisfy { $0.event.source == .cli && $0.event.streamID == made.workerID.uuidString })
        #expect(calls.allSatisfy { $0.progress.status == .completed && $0.startedAtMS != nil })
        #expect(calls[0].event.sessionID == nil && calls[1].event.sessionID != nil)
        #expect(calls[1].event.app?.bundleID == "com.apple.dock", "the application the session drives, as the memory names it")
        #expect(try await reader.sample(CaptureSampleKey(eventID: calls[1].event.eventID, phase: .current)) != nil,
                "the observation left its current sample under its call")
        #expect(try await reader.sample(CaptureSampleKey(eventID: calls[0].event.eventID, phase: .current)) == nil,
                "open_session's first scene is the session's own observation, under an event of its own")
        // The structured results: each observation points to its real sample; the open's to the session's own
        // observation event, whose origin is the open_session call.
        guard case .observation(let opened)? = calls[0].progress.result,
              case .observation(let observed)? = calls[1].progress.result else {
            Issue.record("the two scene tools left no structured result: \(String(describing: calls.map(\.progress.result)))")
            return
        }
        #expect(opened.sessionRevision == 1 && observed.sessionRevision == 2)
        #expect(observed.sample == CaptureSampleKey(eventID: calls[1].event.eventID, phase: .current))
        let origin = try #require(try await reader.event(opened.sample.eventID))
        #expect(origin.kind == .observation && origin.originEventID == calls[0].event.eventID)
        #expect(calls.allSatisfy { ($0.durationMS ?? -1) >= 0 })
        await reader.close()
        #expect(made.broker.queue.entries.isEmpty)
    }

    @Test("the instructions are the core's, shared with the app, and a turn carries them with the command line's defaults",
          .timeLimit(.minutes(1)))
    func theInstructionsAreSharedWithTheApp() async throws {
        #expect(ChatHost.instructions == AgentTurnHost.instructions(role: nil))
        #expect(ChatHost.instructions
            == AutomationTools.instructions + "\n" + BrokeredAutomationSession.openingInstructions)
        #expect(BrokeredAutomationSession.openingInstructions
            .contains("opens an installed application that is not running yet"))
        #expect(!ChatHost.instructions.contains("In this app"))
        #expect(ChatOptions.usage.contains("/release"))

        let made = try Self.compose()
        made.provider.scripts = [[.say("Hello")]]
        try await made.host.run(prompt: "hello", interactive: false, once: true, read: { nil })

        let turn = try #require(made.provider.turns.first)
        #expect(turn.instructions == ChatHost.instructions)
        #expect(turn.prompt == "hello")
        #expect(turn.provider == .claude)
        #expect(turn.sessionID == nil)
        #expect(turn.model == nil, "the conversation names no model: the command line's default")
        #expect(turn.effort == nil, "the chat chooses no effort: the command line's default")
        #expect(!turn.isCompaction && !turn.allowsWebSearch)
        #expect(turn.connectionFile.hasSuffix("/connection.json"))
        #expect(turn.workingDirectory == made.scratch.appendingPathComponent("ProviderWorkspace", isDirectory: true).path)
        #expect(turn.bridgeExecutable == "/usr/bin/true")
        // The child's environment is the inherited one through the Codex allow-list, as the app's worker's is.
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "SHELL", "LANG", "LC_ALL",
                                    "CODEX_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE",
                                    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY"]
        let environment = try #require(turn.environment)
        #expect(environment.keys.allSatisfy(allowed.contains))
        #expect(environment["PATH"] == ProcessInfo.processInfo.environment["PATH"])
        #expect(made.broker.queue.entries.isEmpty)
    }

    @Test("the same request crosses the one core from the chat and from the app's call, with the same tools and outcome",
          .timeLimit(.minutes(1)))
    func theSameRequestCrossesTheCoreFromBothEntries() async throws {
        let script: [Step] = [Self.open, Self.observe, .say("Opened Test.")]

        // The chat's entry: ChatHost, as ChatCommand composes it.
        let chat = try Self.compose()
        chat.provider.scripts = [script]
        try await chat.host.run(prompt: "open Test", interactive: false, once: true, read: { nil })

        // The app's call: the core made as TeamModel makes it, run inside the desktop's turn as TeamModel
        // does, with the app's selection. TeamModel itself, its recorder and its store are the app's and
        // are not here.
        let scratch   = Self.scratch()
        let made      = try Self.desktop(in: scratch)
        let provider  = ScriptedProvider()
        provider.scripts = [script]
        let core      = AgentTurnHost(
            workingDirectory: scratch.appendingPathComponent("work", isDirectory: true),
            bridgeExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            session         : { made.desktop },
            agents          : { _ in (.claude, URL(fileURLWithPath: "/usr/bin/true")) },
            provider        : provider
        )
        var events: [AgentTurnEvent] = []
        try await made.desktop.turn {
            try await core.run(
                prompt   : "open Test",
                selection: ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low),
                sessionID: nil,
                role     : nil
            ) { events.append($0) }
        }
        try await core.close()
        await made.broker.queue.shutdown()

        // The same tools were called through the same loopback host code, with the same results.
        let fromChat = try #require(chat.provider.replies.first)
        let fromApp  = try #require(provider.replies.first)
        #expect(fromChat.count == 2 && fromApp.count == 2)
        #expect(!fromChat.contains(where: Self.isError) && !fromApp.contains(where: Self.isError))
        #expect(fromChat.map { $0["result"]["structuredContent"]["scene"].string }
            == fromApp.map { $0["result"]["structuredContent"]["scene"].string })
        // The same instructions and the same turn shape; the app chooses a model and an effort, the chat leaves both.
        let chatTurn = try #require(chat.provider.turns.first)
        let appTurn  = try #require(provider.turns.first)
        #expect(chatTurn.instructions == appTurn.instructions)
        #expect(chatTurn.prompt == appTurn.prompt)
        #expect(chatTurn.allowsWebSearch == appTurn.allowsWebSearch)
        #expect(chatTurn.model == nil && appTurn.model == "claude-sonnet-5")
        #expect(chatTurn.effort == nil && appTurn.effort == "low")
        // The same outcome: the reply, recorded by each entry its own way, and both desktops given back.
        #expect(try chat.store.list().first?.entries.last?.text == "Opened Test.")
        #expect(events.contains(.provider(.assistant("Opened Test."))))
        #expect(events.last == .provider(.completed))
        #expect(events.contains { if case .tool(let line) = $0 { line.hasPrefix("→ open_session") } else { false } })
        #expect(!chat.desktop.holdsComputer && !made.desktop.holdsComputer)
        #expect(chat.broker.queue.entries.isEmpty && made.broker.queue.entries.isEmpty)
        #expect(!Self.exists(Self.temporaryDirectory(of: chat.provider)))
        #expect(!Self.exists(Self.temporaryDirectory(of: provider)))
    }

    @Test("a turn opens through the broker's queue under the chat's worker id, and the seat stays between turns",
          .timeLimit(.minutes(1)))
    func aTurnOpensThroughTheQueueAndTheSeatStaysBetweenTurns() async throws {
        var during: [SeatQueue.Entry] = []
        var granted: AgentSession?
        var seen: [Bool] = []
        let made = try Self.compose(granted: { session in granted = session })
        made.provider.scripts = [
            [Self.open, Self.observe, .say("Opened")],
            [Self.observe, .say("Still here")]
        ]
        try await made.host.run(
            prompt     : "open Test",
            interactive: true,
            once       : false,
            read       : Self.lines(["look again", "/quit"]) { index in
                // Between turns: the seat is held, no one waits, the idle window has begun and not elapsed.
                if index == 0 { during = made.broker.queue.entries }
                seen.append(made.desktop.holdsComputer)
            }
        )

        #expect(during.map(\.label) == [Self.label])
        #expect(during.map(\.state) == [.acting])
        #expect(seen == [true, true])
        #expect(made.idle.waits.count >= 1)
        let first  = try #require(made.provider.replies.first)
        let second = try #require(made.provider.replies.last)
        #expect(first.count == 2 && !first.contains(where: Self.isError))
        #expect(second.count == 1 && !second.contains(where: Self.isError))
        let opened = try #require(Self.session(of: first[0]))
        #expect(Self.session(of: first[1]) == opened)
        #expect(Self.session(of: second[0]) == opened, "the second turn found the session the first opened")
        #expect(made.provider.ports.count == 2 && made.provider.ports.first == made.provider.ports.last,
                "one loopback host served both turns")

        // /quit ended the chat: the desktop closed, the seat went back and was taken down, the configuration is gone.
        #expect(!made.desktop.holdsComputer)
        #expect(made.desktop.id == nil)
        #expect(made.broker.queue.entries.isEmpty)
        #expect(granted?.isOpen == false)
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
        let saved = try made.store.list()
        #expect(saved.count == 1)
        #expect(saved.first?.entries.map(\.kind).filter { $0 == .user } == [.user, .user])
        #expect(saved.first?.entries.map(\.kind).filter { $0 == .assistant } == [.assistant, .assistant])
        #expect(saved.first?.entries.contains { $0.kind == .tool && $0.text.hasPrefix("→ open_session") } == true)
    }

    @Test("a second turn resumes the provider session the first reported, kept on the conversation",
          .timeLimit(.minutes(1)))
    func aSecondTurnResumesTheSessionTheFirstReported() async throws {
        let made = try Self.compose()
        made.provider.scripts = [
            [.session("provider-session-1"), .say("One")],
            [.say("Two")]
        ]
        try await made.host.run(prompt: "first", interactive: true, once: false,
                                read: Self.lines(["second", "/quit"]))

        #expect(made.provider.turns.map(\.sessionID) == [nil, "provider-session-1"])
        #expect(try made.store.list().first?.providerSessionID == "provider-session-1")
    }

    @Test("an application the open launched is quit when the chat ends, and one already running is left",
          .timeLimit(.minutes(1)))
    func theProvenanceOfTheOpenedApplicationIsKeptToTheEnd() async throws {
        let launched: pid_t = 900_101
        let found   : pid_t = 900_102
        var asked: [pid_t] = []
        let ledger = LaunchLedger { asked.append($0) }
        ledger.record(.openedByAgent, for: launched)

        for pid in [launched, found] {
            let made = try Self.compose(ledger: ledger, holding: pid)
            made.provider.scripts = [[Self.open, .say("Opened")]]
            try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil })
            #expect(!made.desktop.holdsComputer)
            #expect(made.broker.queue.entries.isEmpty)
        }

        #expect(asked == [launched])
        #expect(ledger.provenance(of: launched) == .alreadyRunning)
    }

    @Test("/release closes the session and not the host, and the next turn opens again through the same broker",
          .timeLimit(.minutes(1)))
    func releaseClosesTheSessionAloneAndTheNextTurnOpensAgain() async throws {
        var opens = 0
        var afterRelease: (held: Bool, id: UUID?, entries: Int)?
        let made = try Self.compose(opens: { opens += 1 })
        made.provider.scripts = [
            [Self.open, .say("Opened")],
            [Self.open, .say("Opened again")]
        ]
        try await made.host.run(
            prompt     : "open Test",
            interactive: true,
            once       : false,
            read       : Self.lines(["/release", "open Test again", "/quit"]) { index in
                if index == 1 {
                    afterRelease = (made.desktop.holdsComputer, made.desktop.id, made.broker.queue.entries.count)
                }
            }
        )

        #expect(opens == 2)
        let after = try #require(afterRelease)
        #expect(after.held == false)
        #expect(after.id == nil)
        #expect(after.entries == 0)
        let first  = try #require(made.provider.replies.first?.first)
        let second = try #require(made.provider.replies.last?.first)
        #expect(!Self.isError(first) && !Self.isError(second))
        #expect(Self.session(of: first) != Self.session(of: second), "a new session, not the released one")
        #expect(made.provider.ports.count == 2)
        #expect(made.provider.ports.first == made.provider.ports.last, "the same loopback host served both turns")
        let entries = try #require(try made.store.list().first?.entries)
        #expect(entries.contains { $0.kind == .tool && $0.text.hasPrefix("User released the Seat") })
        #expect(!made.desktop.holdsComputer)
        #expect(made.broker.queue.entries.isEmpty)
    }

    @Test("the idle window gives the seat back between turns, and the next turn opens again",
          .timeLimit(.minutes(1)))
    func theIdleWindowReleasesBetweenTurnsAndTheNextTurnOpensAgain() async throws {
        var opens = 0
        var released = false
        let made = try Self.compose(opens: { opens += 1 })
        made.provider.scripts = [
            [Self.open, .say("Opened")],
            [Self.open, .say("Opened again")]
        ]
        try await made.host.run(
            prompt     : "open Test",
            interactive: true,
            once       : false,
            read       : Self.lines(["open Test again", "/quit"]) { index in
                guard index == 0 else { return }
                await made.idle.elapseOldest()
                await Self.until { !made.desktop.holdsComputer }
                released = !made.desktop.holdsComputer && made.broker.queue.entries.isEmpty
            }
        )

        #expect(released)
        #expect(opens == 2)
        #expect(made.idle.waits.first == BrokeredAutomationSession.idleWindow)
        #expect(made.provider.replies.allSatisfy { !$0.contains(where: Self.isError) })
        #expect(!made.desktop.holdsComputer)
        #expect(made.broker.queue.entries.isEmpty)
    }

    @Test("a one-turn chat ends with the desktop closed, the seat taken down and the configuration removed",
          .timeLimit(.minutes(1)))
    func aOneTurnChatEndsWithEverythingGivenBack() async throws {
        var granted: AgentSession?
        var connection: URL?
        let made = try Self.compose(granted: { granted = $0 })
        made.provider.scripts = [[Self.open, Self.observe, .act {
            connection = Self.temporaryDirectory(of: made.provider)?.appendingPathComponent("connection.json")
        }, .say("Done")]]

        try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil })

        #expect(made.provider.turns.count == 1)
        #expect(made.provider.replies.first?.contains(where: Self.isError) == false)
        #expect(!made.desktop.holdsComputer)
        #expect(made.desktop.activity == nil)
        #expect(made.broker.queue.entries.isEmpty)
        #expect(granted?.isOpen == false, "the parked seat was taken down with the queue")
        #expect(connection != nil, "the connection file existed during the turn")
        #expect(!Self.exists(connection))
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
        let saved = try #require(try made.store.list().first)
        #expect(saved.entries.map(\.kind).contains(.user))
        #expect(saved.entries.last?.kind == .assistant)
        #expect(saved.entries.last?.text == "Done")
        // Again is nothing.
        await made.host.shutdown()
    }

    @Test("a turn that fails outside a terminal closes the desktop, ends the chat and rethrows",
          .timeLimit(.minutes(1)))
    func aFailedTurnOutsideATerminalClosesTheDesktopAndRethrows() async throws {
        var granted: AgentSession?
        let made = try Self.compose(granted: { granted = $0 })
        made.provider.scripts = [[Self.open, .fail("the provider died")]]

        let failure = await #expect(throws: ProviderFailed.self) {
            try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil })
        }
        #expect(failure?.reason == "the provider died")
        #expect(!made.desktop.holdsComputer)
        #expect(made.broker.queue.entries.isEmpty)
        #expect(granted?.isOpen == false)
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
        let entries = try #require(try made.store.list().first?.entries)
        #expect(entries.contains { $0.kind == .error && $0.text == "the provider died" })
    }

    @Test("a turn that fails in a terminal closes the desktop and the chat goes on, opening again",
          .timeLimit(.minutes(1)))
    func aFailedTurnInATerminalClosesTheDesktopAndTheChatGoesOn() async throws {
        var opens = 0
        var afterFailure: Bool?
        let made = try Self.compose(opens: { opens += 1 })
        made.provider.scripts = [
            [Self.open, .fail("the provider died")],
            [Self.open, .say("Opened again")]
        ]
        try await made.host.run(
            prompt     : "open Test",
            interactive: true,
            once       : false,
            read       : Self.lines(["open Test again", "/quit"]) { index in
                if index == 0 { afterFailure = made.desktop.holdsComputer }
            }
        )

        #expect(afterFailure == false, "the failed turn gave the seat back")
        #expect(opens == 2)
        #expect(made.provider.replies.last?.contains(where: Self.isError) == false)
        #expect(!made.desktop.holdsComputer)
        #expect(made.broker.queue.entries.isEmpty)
    }

    /// The transcript directory is made read-only while the turn runs, so the first event's write fails.
    @Test("a transcript write that fails ends the turn with that failure, replays nothing and cleans up",
          .timeLimit(.minutes(1)))
    func aTranscriptWriteThatFailsEndsTheTurnAndIsThrown() async throws {
        let made = try Self.compose()
        let conversations = made.store.directory
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: conversations.path) }
        made.provider.scripts = [[Self.open, .act {
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: conversations.path)
        }, .say("Opened"), .say("never written")]]

        let thrown = await #expect(throws: (any Error).self) {
            try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil })
        }
        #expect(!(thrown is CancellationError), "the transcript's failure, not the stop it caused")
        #expect(!(thrown is Interrupted))
        #expect(made.provider.turns.count == 1, "nothing was run again")
        #expect(!made.desktop.holdsComputer)
        #expect(made.broker.queue.entries.isEmpty)
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
    }

    @Test("a stop during a turn interrupts the provider and cleans up, all before run ends",
          .timeLimit(.minutes(1)))
    func aStopDuringATurnCleansUpBeforeRunEnds() async throws {
        var granted: AgentSession?
        let made = try Self.compose(granted: { granted = $0 })
        made.provider.scripts = [[Self.open, .waitUntilCancelled]]

        let running = Task { try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil }) }
        await Self.until { made.provider.isWaiting }
        #expect(made.desktop.holdsComputer)
        #expect(made.broker.queue.entries.map(\.label) == [Self.label])
        #expect(made.host.agent.isRunning)

        let cleanup = made.host.stop()
        made.host.stop()
        await cleanup.value

        #expect(!made.desktop.holdsComputer)
        #expect(made.desktop.activity == nil)
        #expect(made.broker.queue.entries.isEmpty)
        #expect(granted?.isOpen == false)
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
        await #expect(throws: ChatStopped.self) { try await running.value }
        #expect(!made.host.agent.isRunning)
        let entries = try #require(try made.store.list().first?.entries)
        #expect(entries.filter { $0.kind == .interrupted }.count == 1)
    }

    /// The supervision's probe on S3-b, carried into the repository: `/status` is a diagnostic command
    /// and its call and result belong in the transcript, as they did before the turn core, before the
    /// first turn and after one, each once.
    @Test("/status keeps its call and result in the transcript, before the first turn and after one",
          .timeLimit(.minutes(1)))
    func statusKeepsItsCallAndResultInTheTranscript() async throws {
        let made = try Self.compose()
        try made.host.transcript.save()

        let before = try await made.host.status()
        #expect(before.contains("\"permissions\""))
        let saved = try #require(try made.store.list().first)
        #expect(saved.entries.filter { $0.kind == .tool && $0.text.hasPrefix("→ status") }.count == 1)
        #expect(saved.entries.filter { $0.kind == .tool && $0.text.hasPrefix("← status") }.count == 1)

        made.provider.scripts = [[Self.open, .say("Opened")]]
        try await made.host.run(prompt: "open Test", interactive: true, once: false,
                                read: Self.lines(["/status", "/quit"]))

        let entries = try #require(try made.store.list().first?.entries)
        let tools = entries.filter { $0.kind == .tool }.map(\.text)
        // The turn's own records sit between the two diagnostics, each line once and in order.
        #expect(tools.map { String($0.split(separator: " ").prefix(2).joined(separator: " ")) }
            == ["→ status", "← status", "→ open_session", "← open_session", "→ status", "← status"])
        #expect(tools[1].contains("\"session\":null"), "before the first turn there is no session")
        #expect(!tools[5].contains("\"session\":null"), "after the turn the held session is reported")
    }

    /// `/status` while a turn runs would attribute its records to the turn: the core refuses it, and
    /// the turn goes on unaffected.
    @Test("/status during a turn is refused and the turn goes on", .timeLimit(.minutes(1)))
    func statusDuringATurnIsRefused() async throws {
        let made = try Self.compose()
        made.provider.scripts = [[Self.open, .waitUntilCancelled]]
        let running = Task { try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil }) }
        await Self.until { made.provider.isWaiting }

        let refusal = await #expect(throws: AutomationFailure.self) { _ = try await made.host.status() }
        #expect(refusal?.description.contains("still responding") == true)
        #expect(made.desktop.holdsComputer)

        await made.host.stop().value
        await #expect(throws: ChatStopped.self) { try await running.value }
        let tools = try #require(try made.store.list().first?.entries).filter { $0.kind == .tool }.map(\.text)
        #expect(!tools.contains { $0.hasPrefix("→ status") })
    }

    @Test("a stop while the open waits for the computer leaves the queue with no lease behind",
          .timeLimit(.minutes(1)))
    func aStopWhileWaitingForTheComputerLeavesTheQueue() async throws {
        var wasSeated = false
        let made = try Self.compose(opens: { wasSeated = true })
        let holder = try await made.broker.queue.acquire("holder")
        made.provider.scripts = [[Self.open, .say("never")]]

        let running = Task { try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil }) }
        await Self.until { made.broker.queue.entries.count == 2 }
        #expect(made.broker.queue.entries.map(\.label) == ["holder", Self.label])
        #expect(made.desktop.activity == "Waiting for the computer (1 ahead)")

        await made.host.stop().value

        await #expect(throws: ChatStopped.self) { try await running.value }
        #expect(made.broker.queue.entries.map(\.label) == ["holder"])
        #expect(made.desktop.activity == nil)
        #expect(!made.desktop.holdsComputer)
        #expect(!wasSeated)
        #expect(made.provider.replies.first?.first.map(Self.isError) == true)
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
        holder.giveBack()
        #expect(made.broker.queue.entries.isEmpty)
        await made.broker.queue.shutdown()
    }

    // MARK: Measured stop under a held archive (S4)

    /// The budget of these measures: 400 ms unless `MECUM_MEASURE_FINALIZATION_MS` says otherwise, the
    /// service's production defaults with `MECUM_MEASURE_PRODUCTION=1`. Wide enough that one shared
    /// budget and one per fact are told apart with room for scheduling.
    private static var measuredMemoryConfiguration: MemoryService.Configuration {
        let environment = ProcessInfo.processInfo.environment
        if environment["MECUM_MEASURE_PRODUCTION"] == "1" { return MemoryService.Configuration() }
        let budget = environment["MECUM_MEASURE_FINALIZATION_MS"].flatMap(Int.init) ?? 400
        // The store's own waiting stays at its defaults here: the budget is the service's.
        return MemoryService.Configuration(finalizationBudget: .milliseconds(budget))
    }

    private static func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    /// A turn opens, then observes; the observation's perception lets another writer take the archive, so
    /// the call's first finalization waits as ordinary contention. The chat is stopped there. `release`
    /// lets the other writer go that long after the stop, or never during the cleanup when nil. Prints one
    /// `STOP-MEASURE` line with the phases from the stop (monotonic; the desktop's release polled every
    /// millisecond) and answers what the archive and the transcript kept, read after the cleanup.
    private func measuredStop(release: Duration?) async throws
        -> (cut: Int, observe: AgentCallStatus?, stopToCleanupMS: Int64, turnScope: MemoryFinalizationScope?) {
        let scratch = Self.scratch()
        let memory  = MemoryService(directory: scratch.appendingPathComponent("Knowledge", isDirectory: true),
                                    configuration: Self.measuredMemoryConfiguration)
        try await memory.open()
        var db: OpaquePointer?
        try #require(sqlite3_open(memory.url.path, &db) == SQLITE_OK)
        let holder = try #require(db)
        defer { sqlite3_close(holder) }
        var armed = false
        let made = try Self.compose(memory: memory, perceived: {
            guard armed else { return }
            armed = false
            #expect(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        })
        var turnScope: MemoryFinalizationScope?
        made.provider.scripts = [[Self.open, .act {
            armed = true
            turnScope = made.host.agent.tools.finalizationScope
        }, Self.observe, .waitUntilCancelled]]
        let running = Task { try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil }) }
        let deadline = ContinuousClock.now + .seconds(10)
        // The store's own count of writes it holds for the lock, as the status prints it.
        while await !memory.status().technicalDetails.contains(where: { $0.contains(", 1 writes waiting") }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(made.desktop.holdsComputer)

        let stop = ContinuousClock.now
        let cleanup = made.host.stop()
        let releasing = release.map { delay in Task { @MainActor in
            try? await Task.sleep(for: delay)
            sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
        } }
        var desktopReleased: Duration?
        while desktopReleased == nil, ContinuousClock.now < stop + .seconds(60) {
            if !made.desktop.holdsComputer { desktopReleased = ContinuousClock.now - stop }
            else { try await Task.sleep(for: .milliseconds(1)) }
        }
        await cleanup.value
        let cleaned = ContinuousClock.now - stop
        await releasing?.value
        sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
        await #expect(throws: ChatStopped.self) { try await running.value }

        #expect(await memory.status().state == .closed, "the host closed the memory last")
        #expect(made.broker.queue.entries.isEmpty)
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
        let gaps = try #require(try made.store.list().first?.entries).filter { $0.kind == .tool && $0.text.hasPrefix("← memory") }
        let reader = MemoryService(directory: memory.directory)
        try await reader.openForReading()
        let trace = try #require(try await reader.traces(before: nil, limit: 5).first?.traceID)
        let calls = try await reader.calls(inTrace: trace, after: nil, limit: 10)
        let observe = calls.first { $0.request.tool == .observe }?.progress.status
        await reader.close()
        print("STOP-MEASURE case=chat-stop-\(release == nil ? "permanent-lock" : "released-within-budget") "
              + "budgetMs=\(Self.ms(Self.measuredMemoryConfiguration.finalizationBudget)) "
              + "stopToDesktopReleasedMs=\(desktopReleased.map { String(Self.ms($0)) } ?? "never") "
              + "stopToCleanupMs=\(Self.ms(cleaned)) cut=\(gaps.count) observeRow=\(observe.map { "\($0)" } ?? "none") "
              + "calls=\(calls.map { "\($0.request.tool)=\($0.progress.status)" }) queue=\(made.broker.queue.entries.count) "
              + "memory=closed")
        return (gaps.count, observe, Self.ms(cleaned), turnScope)
    }

    @Test("measured: a stop while the observation waits for an archive that is never released ends after one budget per cut fact, then cleans up",
          .timeLimit(.minutes(3)))
    func measuredStopUnderAPermanentLock() async throws {
        let budget = Self.ms(Self.measuredMemoryConfiguration.finalizationBudget)
        let measured = try await measuredStop(release: nil)
        #expect(measured.cut >= 1, "the sample, and the conclusion after it, are cut and said")
        #expect(measured.observe == .started, "the observation's outcome is unknown to the record, never invented")
        #expect(measured.cut == 2, "the sample and the call's end")
        #expect(measured.turnScope?.stopInstant != nil, "the turn's owner was stopped by the host's stop")
        // The sample, cut in the session's recorder, and the call's end share the turn's budget: the
        // owner reached the recorder through the router's task and the session (one budget, not two).
        #expect(measured.stopToCleanupMS >= budget)
        #expect(measured.stopToCleanupMS < budget * 3 / 2, "one budget for the turn's memory, not one per fact")
    }

    @Test("measured: a stop while the observation waits, with the archive released within the budget, saves what was known and cleans up",
          .timeLimit(.minutes(3)))
    func measuredStopWithTheLockReleased() async throws {
        let budget = Self.ms(Self.measuredMemoryConfiguration.finalizationBudget)
        let measured = try await measuredStop(release: .milliseconds(budget / 2))
        #expect(measured.cut == 0)
        #expect(measured.observe == .completed || measured.observe == .cancelled)
    }

    @Test("each turn is a new owner of the memory's budget, and none is left once the turn ends",
          .timeLimit(.minutes(1)))
    func eachTurnHasItsOwnFinalizationScope() async throws {
        let made = try Self.compose()
        var scopes: [MemoryFinalizationScope?] = []
        made.provider.scripts = [
            [.act { scopes.append(made.host.agent.tools.finalizationScope) }, .say("one")],
            [.act { scopes.append(made.host.agent.tools.finalizationScope) }, .say("two")],
        ]
        try await made.host.run(prompt: "first", interactive: true, once: false, read: Self.lines(["second", "/quit"]))
        #expect(scopes.count == 2)
        #expect(scopes.allSatisfy { $0 != nil })
        #expect(scopes.first.flatMap { $0 } !== scopes.last.flatMap { $0 }, "the second turn has a new owner")
        #expect(made.host.agent.tools.finalizationScope == nil, "no owner outside a turn: a call then is its own")
    }

    // MARK: The invocation's configuration

    /// A synthetic environment: what the allow-list keeps and what it drops, with values that are not
    /// credentials and are not printed.
    private static let syntheticEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin", "HOME": "/Users/synthetic", "CODEX_HOME": "/Users/synthetic/.codex",
        "TERM": "xterm-256color", "ANTHROPIC_API_KEY": "fake-0001", "OPENAI_API_KEY": "fake-0002",
        "ANTHROPIC_BASE_URL": "https://example.invalid", "SHELL": "/bin/zsh",
    ]

    @Test("the invocation's role, effort, web search and model reach the turn as a worker's do",
          .timeLimit(.minutes(1)))
    func theInvocationsConfigurationReachesTheTurn() async throws {
        let made = try Self.compose(model: "claude-opus-5", role: "  Edit video.  ", effort: .high, webSearch: true,
                                    environment: Self.syntheticEnvironment)
        made.provider.scripts = [[.say("ok")]]
        try await made.host.run(prompt: "hello", interactive: false, once: true, read: { nil })

        let turn = try #require(made.provider.turns.first)
        #expect(turn.instructions == AgentTurnHost.instructions(role: "  Edit video.  ", searchesWeb: true))
        #expect(turn.instructions.hasSuffix("\n\nYour role:\nEdit video."), "the role's text, trimmed by the core")
        #expect(turn.instructions.contains(AgentTurnHost.webInstructions))
        #expect(turn.effort == "high")
        #expect(turn.model == "claude-opus-5")
        #expect(turn.allowsWebSearch)
        #expect(!turn.isCompaction)
        // The child's environment: launch and login settings only, nothing else of the synthetic set.
        #expect(turn.environment == ["PATH": "/usr/bin:/bin", "HOME": "/Users/synthetic",
                                     "CODEX_HOME": "/Users/synthetic/.codex", "SHELL": "/bin/zsh"])
        #expect(made.host.effortRefusal() == nil)
    }

    @Test("the same explicit configuration crosses the one core from the chat and from the app's call",
          .timeLimit(.minutes(1)))
    func theSameExplicitConfigurationCrossesTheCoreFromBothEntries() async throws {
        let script: [Step] = [Self.open, Self.observe, .say("Opened Test.")]
        let role   = "Be brief."

        let chat = try Self.compose(model: "claude-sonnet-5", role: role, effort: .low, webSearch: true,
                                    environment: Self.syntheticEnvironment)
        chat.provider.scripts = [script]
        try await chat.host.run(prompt: "open Test", interactive: false, once: true, read: { nil })

        // The app's call: the worker's selection, role and web preference, as TeamModel passes them.
        let scratch  = Self.scratch()
        let made     = try Self.desktop(in: scratch)
        let provider = ScriptedProvider()
        provider.scripts = [script]
        let core = AgentTurnHost(
            workingDirectory: scratch.appendingPathComponent("work", isDirectory: true),
            bridgeExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            session         : { made.desktop },
            agents          : { _ in (.claude, URL(fileURLWithPath: "/usr/bin/true")) },
            provider        : provider
        )
        var events: [AgentTurnEvent] = []
        try await made.desktop.turn {
            try await core.run(
                prompt              : "open Test",
                selection           : ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low),
                sessionID           : nil,
                role                : role,
                allowsWebSearch     : true,
                inheritedEnvironment: Self.syntheticEnvironment
            ) { events.append($0) }
        }
        try await core.close()
        await made.broker.queue.shutdown()

        let chatTurn = try #require(chat.provider.turns.first)
        let appTurn  = try #require(provider.turns.first)
        #expect(chatTurn.instructions == appTurn.instructions)
        #expect(chatTurn.instructions.hasSuffix("\n\nYour role:\n" + role))
        #expect(chatTurn.provider == appTurn.provider)
        #expect(chatTurn.model == appTurn.model && chatTurn.model == "claude-sonnet-5")
        #expect(chatTurn.effort == appTurn.effort && chatTurn.effort == "low")
        #expect(chatTurn.allowsWebSearch && appTurn.allowsWebSearch)
        #expect(chatTurn.environment == appTurn.environment)
        #expect(chatTurn.isCompaction == appTurn.isCompaction)
        #expect(chatTurn.prompt == appTurn.prompt)
        // The hosts' own: the bridge and the working directory differ by design, and are both stable.
        #expect(chatTurn.workingDirectory != appTurn.workingDirectory)
        let fromChat = try #require(chat.provider.replies.first)
        let fromApp  = try #require(provider.replies.first)
        #expect(fromChat.map { $0["result"]["structuredContent"]["scene"].string }
            == fromApp.map { $0["result"]["structuredContent"]["scene"].string })
        #expect(try chat.store.list().first?.entries.last?.text == "Opened Test.")
        #expect(events.contains(.provider(.assistant("Opened Test."))))
        #expect(!chat.desktop.holdsComputer && !made.desktop.holdsComputer)
    }

    @Test("an effort the model does not take is refused before the turn, and after /model changes the model",
          .timeLimit(.minutes(1)))
    func anUnsupportedEffortIsRefusedBeforeTheTurn() async throws {
        var opens = 0
        let made = try Self.compose(model: "claude-haiku-4-5", effort: .high, opens: { opens += 1 })
        made.provider.scripts = [[Self.open, .say("never")]]
        let refusal = try #require(made.host.effortRefusal())
        #expect(refusal.contains("takes no reasoning effort for model claude-haiku-4-5"))

        let thrown = await #expect(throws: AutomationFailure.self) {
            try await made.host.run(prompt: "open Test", interactive: false, once: true, read: { nil })
        }
        #expect(thrown?.description == refusal)
        #expect(made.provider.turns.isEmpty, "the provider never ran")
        #expect(opens == 0, "nothing was opened")
        #expect(made.broker.queue.entries.isEmpty)
        let entries = try #require(try made.store.list().first?.entries)
        #expect(entries.contains { $0.kind == .error && $0.text == refusal })

        // A fitting model first, then the model changed under the invocation's effort, as /model does.
        let fitting = try Self.compose(model: "claude-opus-5", effort: .max)
        #expect(fitting.host.effortRefusal() == nil)
        fitting.host.transcript.conversation.model = "claude-haiku-4-5"
        #expect(fitting.host.effortRefusal() != nil)
        fitting.provider.scripts = [[.say("never")]]
        await #expect(throws: AutomationFailure.self) {
            try await fitting.host.run(prompt: "hello", interactive: false, once: true, read: { nil })
        }
        #expect(fitting.provider.turns.isEmpty)
    }

    @Test("a resumed Codex conversation is told its new instructions once, across invocations",
          .timeLimit(.minutes(1)))
    func aResumedCodexConversationIsRemindedOnceAcrossInvocations() async throws {
        // The first invocation: no role; two turns of one Codex thread.
        let first = try Self.compose(commandLine: .codex)
        first.provider.scripts = [[.session("thread-1"), .say("One")], [.say("Two")]]
        try await first.host.run(prompt: "first", interactive: true, once: false, read: Self.lines(["second", "/quit"]))
        #expect(first.provider.turns.map(\.sessionID) == [nil, "thread-1"])
        #expect(first.provider.turns.map(\.prompt) == ["first", "second"], "the same instructions: no reminder")

        // A later invocation with --resume and a role: the thread is reminded once, ahead of the message.
        let second = try Self.compose(commandLine: .codex, role: "Edit video.", resuming: first)
        second.provider.scripts = [[.say("Three")], [.say("Four")]]
        try await second.host.run(prompt: "third", interactive: true, once: false, read: Self.lines(["fourth", "/quit"]))
        let prompts = second.provider.turns.map(\.prompt)
        #expect(second.provider.turns.map(\.sessionID) == ["thread-1", "thread-1"])
        #expect(prompts.first?.hasPrefix("Your instructions changed") == true)
        #expect(prompts.first?.hasSuffix("The person's message:\n\nthird") == true)
        #expect(prompts.first?.contains("Your role:\nEdit video.") == true)
        #expect(prompts.last == "fourth", "told once")
        #expect(second.provider.turns.allSatisfy { $0.instructions == AgentTurnHost.instructions(role: "Edit video.") })

        // The same role again in a third invocation: nothing to remind.
        let third = try Self.compose(commandLine: .codex, role: "Edit video.", resuming: second)
        third.provider.scripts = [[.say("Five")]]
        try await third.host.run(prompt: "fifth", interactive: false, once: true, read: { nil })
        #expect(third.provider.turns.map(\.prompt) == ["fifth"])
    }

    /// The transcript directory is made read-only before `/status`, so its first record cannot be kept.
    @Test("a /status record that cannot be kept is thrown to the caller, and status is not run again",
          .timeLimit(.minutes(1)))
    func aStatusRecordThatCannotBeKeptIsThrown() async throws {
        let made = try Self.compose()
        let conversations = made.store.directory
        try made.host.transcript.save()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: conversations.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: conversations.path) }

        let thrown = await #expect(throws: (any Error).self) { _ = try await made.host.status() }
        #expect(!(thrown is AutomationFailure) && !(thrown is CancellationError))
        #expect(!made.host.agent.isRunning)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: conversations.path)
        let entries = try #require(try made.store.list().first?.entries)
        #expect(!entries.contains { $0.kind == .tool }, "nothing was kept, and nothing was run again to keep it")
        await made.host.shutdown()
    }

    // MARK: Usage and compaction (S3-e)

    @Test("what a turn cost is kept once, from the core's usage, with an unknown context said as unknown",
          .timeLimit(.minutes(1)))
    func aTurnsUsageIsKeptOnce() async throws {
        let made = try Self.compose()
        made.provider.scripts = [
            [.session("claude-1"), .usage(ProviderUsage(tokens: .init(input: 1200, cacheReads: 800, output: 40, reasoning: 5),
                                                         model: "claude-sonnet-5", contextWindow: 200_000)), .say("One")],
            [.say("Two, no usage")],
        ]
        var report = ""
        try await made.host.run(prompt: "first", interactive: true, once: false,
                                read: Self.lines(["second", "/usage", "/quit"], before: { index in
                                    if index == 2 { report = made.host.usageReport() }
                                }))
        let entries = try #require(try made.store.list().first?.entries)
        let usage = entries.filter { $0.kind == .tool && $0.text.hasPrefix("usage:") }.map(\.text)
        #expect(usage.count == 1, "one line for the one turn that reported, none for the turn that did not: \(usage)")
        #expect(usage.first?.contains("this turn 1200 in (800 cache read, 0 cache write), 40 out (5 reasoning)") == true)
        #expect(usage.first?.contains("context unknown of 200000 tokens") == true, "an unreported context is unknown, not 0")
        #expect(usage.first?.contains("session total") == false, "Claude reports no session total")
        #expect(made.host.usages.count == 1)
        #expect(report.contains("own counts summed over 1: 1200 in, 40 out"))
    }

    @Test("a Codex session total is counted from the one before in the chat; a resumed chat says its first turn's own count is unknown",
          .timeLimit(.minutes(1)))
    func codexTotalsAreNotCountedTwice() async throws {
        let scratch = Self.scratch()
        let codexHome = scratch.appendingPathComponent("codex-home", isDirectory: true)
        let environment = ["CODEX_HOME": codexHome.path, "PATH": "/usr/bin:/bin"]
        func total(_ input: Int, _ output: Int) -> ProviderUsage {
            ProviderUsage(tokens: .init(input: input, output: output), isSessionTotal: true)
        }
        var made = try Self.compose(commandLine: .codex, environment: environment)
        made.provider.scripts = [[.session("thread-1"), .usage(total(1000, 10)), .say("One")],
                                 [.usage(total(1500, 15)), .say("Two")]]
        try await made.host.run(prompt: "first", interactive: true, once: false, read: Self.lines(["second", "/quit"]))
        #expect(made.host.usages.map(\.usage.turn.input) == [1000, 500], "the second turn is the total less the first")
        #expect(made.host.usages.allSatisfy { $0.ownCountKnown })
        #expect(made.host.usages.map { $0.usage.sessionTotal?.input } == [1000, 1500])
        // A later `--resume`: the saved conversation keeps no usage, so the first turn's own share is unknown.
        made = try Self.compose(commandLine: .codex, environment: environment, resuming: made)
        made.provider.scripts = [[.usage(total(2100, 20)), .say("Three")]]
        try await made.host.run(prompt: "third", interactive: false, once: true, read: { nil })
        let resumed = try #require(made.host.usages.first)
        #expect(!resumed.ownCountKnown)
        #expect(ChatHost.usageLine(resumed.usage, ownCountKnown: false).contains("this turn unknown"))
        #expect(!ChatHost.usageLine(resumed.usage, ownCountKnown: false).contains("this turn 2100"))
        #expect(made.host.usageReport().contains("1 with an unknown own count left out"))
    }

    @Test("/compact compacts the session through the core as the app does: no tool, no Seat, its outcome kept",
          .timeLimit(.minutes(1)))
    func compactRunsThroughTheCore() async throws {
        var opens = 0
        let made = try Self.compose(opens: { opens += 1 })
        made.provider.scripts = [[.session("claude-1"), .say("One")], [.compacted(5000, 1200)]]
        try await made.host.run(prompt: "first", interactive: true, once: false, read: Self.lines(["/compact", "/quit"]))
        #expect(made.provider.turns.count == 2)
        let compaction = try #require(made.provider.turns.last)
        #expect(compaction.isCompaction && compaction.sessionID == "claude-1")
        #expect(compaction.model == nil, "the conversation names no model: the command line's default")
        #expect(made.provider.replies.last?.isEmpty == true, "the compaction called no tool")
        #expect(opens == 0, "no Seat was asked for")
        let entries = try #require(try made.store.list().first?.entries)
        #expect(entries.contains { $0.kind == .tool && $0.text == "compaction: Claude manual · context 5000 → 1200 tokens of an unknown window" })
        #expect(!entries.contains { $0.kind == .error })
    }

    @Test("a compaction with nothing to compact, or that did not compact, fails with the reason and the chat goes on",
          .timeLimit(.minutes(1)))
    func aFailedCompactionInventsNothing() async throws {
        let made = try Self.compose()
        made.provider.scripts = [[.session("claude-1"), .say("One")], [.say("I could not")]]
        // The first /compact has no session yet; the provider is not even started for it.
        try await made.host.run(prompt: "/compact", interactive: true, once: false,
                                read: Self.lines(["first", "/compact", "/quit"]))
        let entries = try #require(try made.store.list().first?.entries)
        let errors = entries.filter { $0.kind == .error }.map(\.text)
        #expect(errors.count == 2, "\(errors)")
        #expect(errors.first?.hasPrefix("Compaction failed: There is nothing to compact yet") == true)
        #expect(errors.last == "Compaction failed: I could not", "the provider's own last words, as the app reports them")
        #expect(!entries.contains { $0.text.hasPrefix("compaction:") }, "no result was invented")
        #expect(made.provider.turns.filter(\.isCompaction).count == 1)
    }

    @Test("a stop during a compaction ends it, records the interruption and cleans up, with no result kept",
          .timeLimit(.minutes(1)))
    func aStopDuringACompaction() async throws {
        let made = try Self.compose()
        made.provider.scripts = [[.session("claude-1"), .say("One")], [.waitUntilCancelled]]
        let running = Task {
            try await made.host.run(prompt: "first", interactive: true, once: false, read: Self.lines(["/compact"]))
        }
        await Self.until { made.provider.isWaiting }
        #expect(made.host.agent.isRunning)
        await made.host.stop().value
        await #expect(throws: ChatStopped.self) { try await running.value }
        let entries = try #require(try made.store.list().first?.entries)
        #expect(entries.filter { $0.kind == .interrupted }.count == 1)
        #expect(!entries.contains { $0.text.hasPrefix("compaction:") || $0.text.hasPrefix("Compaction failed") })
        #expect(!Self.exists(Self.temporaryDirectory(of: made.provider)))
    }
}

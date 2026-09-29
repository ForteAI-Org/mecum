import ChatCore
import AutomationMCP
import CLIProviders
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteLivingMemory
import Testing

/// SyntheticProviderTests contact the user's signed-in providers only when explicitly enabled.
/// The MCP host returns fixed invented data and has no dependency on AppKit, perception or Driver.
@Suite("Signed-in providers with synthetic MCP data", .serialized)
struct SyntheticProviderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MECUM_SYNTHETIC_PROVIDER_TESTS"] == "1"),
          arguments: ChatProvider.allCases)
    func signedInTurnAndResume(_ provider: ChatProvider) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-synthetic-\(provider.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let definitions = AutomationTools.definitions
        var calls: [String] = []
        let router = MCPRouter(tools: definitions) { name, _ in
            calls.append(name)
            return MCPRouter.toolResult(.object([
                "synthetic": .bool(true),
                "application": .string("Synthetic Mixer"),
                "window": .string("Synthetic New Paths"),
                "permissions": .string("synthetic-granted"),
                "session": .null
            ]))
        }
        let host = LocalMCPHost(router: router)
        let endpoint = try await host.start()
        defer { host.stop() }
        let connection = root.appendingPathComponent("connection.json")
        try JSONEncoder().encode(endpoint).write(to: connection)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connection.path)
        let cli = try #require(executable(provider.rawValue))
        let bridge = try #require(ProcessInfo.processInfo.environment["MECUM_TEST_BRIDGE"])
        let runner = CLIProvider()
        var sessionID: String?
        var replies: [String] = []
        let instructions = """
        This is a synthetic MCP integration test. Only use the supplied mecum status and windows tools.
        Never inspect real apps, files, environment, or the computer. No other tool is needed or permitted.
        Call both mecum tools on each user turn and answer briefly from their synthetic results.
        """
        let first = ProviderTurn(
            provider: provider, model: provider == .claude ? "sonnet" : nil, sessionID: nil,
            prompt: "Remember the codeword copper-otter. Call both synthetic tools and report their invented app and window.",
            instructions: instructions, bridgeExecutable: bridge,
            connectionFile: connection.path, workingDirectory: root.path
        )
        try await runner.run(first, executable: cli) { event in
            if case .session(let id) = event { sessionID = id }
            if case .assistant(let text) = event { replies.append(text) }
        }
        let rememberedSession = try #require(sessionID)
        try #require(calls.contains("status") && calls.contains("windows"))
        try #require(replies.joined().contains("Synthetic Mixer"))
        calls = []
        replies = []
        let second = ProviderTurn(
            provider: provider, model: first.model, sessionID: rememberedSession,
            prompt: "Call both synthetic tools again. What codeword did I ask you to remember?",
            instructions: instructions, bridgeExecutable: bridge,
            connectionFile: connection.path, workingDirectory: root.path
        )
        try await runner.run(second, executable: cli) { event in
            if case .session(let id) = event { #expect(id == rememberedSession) }
            if case .assistant(let text) = event { replies.append(text) }
        }
        try #require(calls.contains("status") && calls.contains("windows"))
        try #require(replies.joined().lowercased().contains("copper-otter"))
        print("Synthetic provider verified: \(provider.rawValue), tool calls on both turns, exact session resumed.")
    }

    // MARK: Learning, reopening and recall through a provider

    nonisolated private static let enabled =
        ProcessInfo.processInfo.environment["MECUM_SYNTHETIC_PROVIDER_TESTS"] == "1"

    private let learning = "Seleziona Output Busses nel filtro e verifica il nuovo valore. "
        + "Fermati se il controllo non è univoco."
    private let recalling = "Seleziona Output Busses nel filtro. Prima dimmi se "
        + "hai un’esperienza verificata che può aiutare; poi osserva la finestra attuale e agisci solo se il "
        + "controllo è presente."

    /// The only tools the synthetic server offers: none of them reads a real application or window.
    private static let syntheticTools: Set<String> = ["open_session", "observe", "select", "act"]

    private static let syntheticInstructions = ChatInstructions.standard + """

    This is a synthetic integration test with invented data. The only mecum tools here are open_session,
    observe, select and act: status and windows do not exist, so skip them. The application is "Synthetic Mixer".
    Never inspect real apps, files, the environment or the computer. Do not close the session.
    When a <mecum-memory> block is present, quote its remembered experienceID verbatim in your reply.
    """

    @Test(.enabled(if: SyntheticProviderTests.enabled))
    func claudeLearnsThenRecallsInANewConversation() async throws {
        try await learnThenRecall(.claude)
    }

    @Test(.enabled(if: SyntheticProviderTests.enabled))
    func codexLearnsThenRecallsInANewConversation() async throws {
        try await learnThenRecall(.codex)
    }

    private struct ActionCase: Sendable, CustomStringConvertible {
        let verb: String
        let target: String
        let request: String
        let step: ExperienceStep

        var description: String { verb }
    }

    nonisolated private static let actionCases: [ActionCase] = {
        let cases: [ActionCase] = [
            ActionCase(verb: "set_toggle", target: "Mute", request: "Attiva Mute",
                       step: .setToggle(control: "Mute", section: nil, state: .on)),
            ActionCase(verb: "click", target: "File", request: "Clicca File per aprire il menu",
                       step: .click(.click, target: "File", section: nil, opens: .menu)),
            ActionCase(verb: "double_click", target: "Project",
                       request: "Fai doppio clic su Project per aprirlo",
                       step: .click(.doubleClick, target: "Project", section: nil,
                                    opens: .window(title: "Project 1"))),
            ActionCase(verb: "right_click", target: "Track 1", request: "Fai clic destro su Track 1",
                       step: .click(.rightClick, target: "Track 1", section: nil, opens: .menu)),
        ]
        guard let only = ProcessInfo.processInfo.environment["MECUM_SYNTHETIC_ACTION"] else { return cases }
        return cases.filter { $0.verb == only }
    }()

    @Test(.enabled(if: SyntheticProviderTests.enabled),
          arguments: ChatProvider.allCases, actionCases)
    private func signedInActionLearnsAndRecalls(_ provider: ChatProvider, _ action: ActionCase) async throws {
        try await learnThenRecallAction(provider, action)
    }

    /// Each provider must choose and call act, then receive recall from a reopened temporary store.
    /// The synthetic session supplies typed proof; separate Engine tests verify its real producers.
    private func learnThenRecallAction(_ provider: ChatProvider, _ action: ActionCase) async throws {
        guard let cli = executable(provider.rawValue) else {
            try Test.cancel("\(provider.rawValue) CLI is not installed: not run, not passed")
        }
        let bridge = try #require(ProcessInfo.processInfo.environment["MECUM_TEST_BRIDGE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-synthetic-action-\(provider.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = root.appendingPathComponent("Knowledge", isDirectory: true)
        let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)

        let firstSessionID: String
        let learnedID: String
        do {
            let first = try SyntheticChat(knowledge: knowledge, file: file, action: action)
            let start = try await first.cycle.begin(action.request, sessionIsOpen: false)
            #expect(start.memory?.briefing == nil)
            let run = try await first.run(provider, cli: cli, bridge: bridge, prompt: start.prompt, root: root)
            let end = try #require(await first.cycle.end(.completed))
            let expectedReason: TurnAdmission.Reason = action.verb == "set_toggle"
                ? .admittedSingleToggle : .admittedSingleClick
            #expect(end.report.decision.reason == expectedReason)
            let record = try #require(try await first.store.experiences(in: ["test.synthetic.mixer"]).first)
            #expect(record.step == action.step)
            #expect(record.successCount == 1)
            #expect(run.tools.contains("act"))
            #expect(run.requests.contains { name, arguments in
                name == "act" && arguments["target"].string == action.target
                    && arguments["verb"].string == action.verb
                    && (action.verb != "set_toggle" || arguments["value"].string == "on")
            })
            firstSessionID = try #require(run.sessionID)
            learnedID = record.id.rawValue
        }

        let second = try SyntheticChat(knowledge: knowledge, file: file, action: action)
        let start = try await second.cycle.begin(action.request, sessionIsOpen: false)
        let briefing = try #require(start.memory?.briefing)
        #expect(briefing.status == "suggested")
        #expect(briefing.remembered?.experienceID == learnedID)
        #expect(briefing.remembered?.tool == action.verb)
        let run = try await second.run(provider, cli: cli, bridge: bridge, prompt: start.prompt, root: root)
        let end = try #require(await second.cycle.end(.completed))
        #expect(run.sessionID != nil && run.sessionID != firstSessionID)
        #expect(run.replies.joined().contains(learnedID))
        #expect(run.tools.contains("act"))
        #expect(end.report.decision.reason == .confirmsFollowedExperience)
        let record = try #require(try await second.store.experiences(in: ["test.synthetic.mixer"]).first)
        #expect(record.id.rawValue == learnedID)
        #expect(record.successCount == 2)
        #expect(run.tools.first == "open_session" || run.tools.first == "observe",
                "the model needs a fresh scene before it can act")
        if action.verb == "set_toggle" {
            try await checkNonUse(provider, action: action, cli: cli, bridge: bridge,
                                  root: root, knowledge: knowledge, file: file,
                                  learnedID: learnedID)
        }
        print("Synthetic action memory verified: \(provider.rawValue), \(action.verb), "
              + "tool calls and typed proof across two provider conversations.")
    }

    /// A learned toggle is never confirmed from an absent or ambiguous target, nor from another
    /// app or window. An unreliable record may still be independently verified, but is not followed.
    private func checkNonUse(
        _ provider: ChatProvider, action: ActionCase, cli: URL, bridge: String,
        root: URL, knowledge: URL, file: URL, learnedID: String
    ) async throws {
        struct Context {
            let name: String
            let bundleID: String
            let windowTitle: String
            let labels: [String]
            let statusAfterObservation: String
        }
        let contexts = [
            Context(name: "other app", bundleID: "test.other.mixer", windowTitle: "Synthetic New Paths",
                    labels: ["Mute"], statusAfterObservation: "refused"),
            Context(name: "other window", bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Other Window",
                    labels: ["Mute"], statusAfterObservation: "historical"),
            Context(name: "absent", bundleID: "test.synthetic.mixer", windowTitle: "Synthetic New Paths",
                    labels: ["Solo"], statusAfterObservation: "historical"),
            Context(name: "ambiguous", bundleID: "test.synthetic.mixer", windowTitle: "Synthetic New Paths",
                    labels: ["Mute", "Mute"], statusAfterObservation: "historical"),
        ]
        for context in contexts {
            let chat = try SyntheticChat(
                knowledge: knowledge, file: file, action: action, bundleID: context.bundleID,
                windowTitle: context.windowTitle, visibleLabels: context.labels
            )
            let start = try await chat.cycle.begin(action.request, sessionIsOpen: false)
            #expect(start.memory?.briefing?.currentEvidence == "notObserved")
            let diagnostic = start.prompt + "\nFor this diagnostic, open the synthetic session, inspect the "
                + "current scene and memory, and report whether the memory applies. Do not act."
            let run = try await chat.run(provider, cli: cli, bridge: bridge, prompt: diagnostic, root: root)
            _ = try #require(await chat.cycle.end(.completed))
            #expect(run.tools.contains("open_session") || run.tools.contains("observe"))
            #expect(!run.tools.contains("act"), "\(context.name) acted despite the explicit diagnostic request")
            let statuses = run.responses.compactMap { name, value in
                ["open_session", "observe"].contains(name)
                    ? value["structuredContent"]["memory"]["status"].string : nil
            }
            #expect(statuses.contains(context.statusAfterObservation),
                    "\(context.name) reported statuses \(statuses), not \(context.statusAfterObservation)")
            let old = try #require(try await chat.store.experiences(in: ["test.synthetic.mixer"])
                .first(where: { $0.id.rawValue == learnedID }))
            #expect(old.successCount == 2, "\(context.name) confirmed the old experience")
        }

        let store = try SQLiteLivingMemoryStore(file: file)
        for index in 0 ..< 3 {
            _ = try await store.record(ExperienceEvent(
                id: "provider-unreliable-\(provider.rawValue)-\(index)",
                subject: .experience(ExperienceID(learnedID)),
                outcome: .contradicted(.userCorrection),
                at: Date().addingTimeInterval(Double(index + 1))
            ))
        }
        let unreliable = try SyntheticChat(knowledge: knowledge, file: file, action: action)
        let start = try await unreliable.cycle.begin(action.request, sessionIsOpen: false)
        #expect(start.memory?.briefing?.status == "refused")
        #expect(start.memory?.followed == nil)
        let diagnostic = start.prompt + "\nFor this diagnostic, open the synthetic session, inspect the "
            + "current scene and memory, and report whether the memory applies. Do not act."
        let run = try await unreliable.run(provider, cli: cli, bridge: bridge, prompt: diagnostic, root: root)
        let end = try #require(await unreliable.cycle.end(.completed))
        #expect(run.tools.contains("open_session") || run.tools.contains("observe"))
        #expect(!run.tools.contains("act"))
        #expect(end.report.decision.reason != .confirmsFollowedExperience)
    }

    /// Two store instances over one temporary knowledge directory and two provider conversations: the
    /// first learns through the provider's own tool calls, the second starts with no session id and
    /// receives what recall reads back from disk.
    private func learnThenRecall(_ provider: ChatProvider) async throws {
        guard let cli = executable(provider.rawValue) else {
            try Test.cancel("\(provider.rawValue) CLI is not installed: not run, not passed")
        }
        let bridge = try #require(ProcessInfo.processInfo.environment["MECUM_TEST_BRIDGE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-synthetic-memory-\(provider.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = root.appendingPathComponent("Knowledge", isDirectory: true)
        let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)

        let firstSessionID: String
        do {
            let first = try SyntheticChat(knowledge: knowledge, file: file)
            let start = try await first.cycle.begin(learning, sessionIsOpen: false)
            #expect(start.memory?.briefing == nil)
            let run = try await first.run(provider, cli: cli, bridge: bridge, prompt: start.prompt, root: root)
            let end = try #require(await first.cycle.end(.completed))
            guard case .recorded(.applied(_?), .admittedSingleSelection)? = end.recording else {
                let reply = String(run.replies.joined(separator: " ").prefix(600))
                let why = "the first turn taught nothing: \(end.report.decision.reason), tools \(run.tools), "
                    + "reply \(reply)"
                Issue.record(Comment(rawValue: why))
                return
            }
            firstSessionID = try #require(run.sessionID)
        }

        let second = try SyntheticChat(knowledge: knowledge, file: file)
        let start = try await second.cycle.begin(recalling, sessionIsOpen: false)
        let briefing = try #require(start.memory?.briefing)
        let remembered = try #require(briefing.remembered)
        #expect(briefing.status == "suggested")
        #expect(remembered.originalRequest == learning)
        #expect(remembered.item == "Output Busses")
        #expect(remembered.application == "test.synthetic.mixer")
        #expect(remembered.window == "syntheticnewpaths")
        #expect(start.prompt.hasPrefix("<mecum-memory>\n") && start.prompt.hasSuffix("\n\n" + recalling))
        let run = try await second.run(provider, cli: cli, bridge: bridge, prompt: start.prompt, root: root)
        _ = await second.cycle.end(.completed)
        #expect(run.sessionID != nil && run.sessionID != firstSessionID)
        #expect(run.replies.joined().contains(remembered.experienceID))
        #expect(try await second.store.experiences(in: ["test.synthetic.mixer"]).count == 1)
        print("Synthetic memory verified: \(provider.rawValue), learned in one conversation, recalled from disk "
              + "in a new one (tools \(run.tools)).")
    }

    /// SyntheticChat is one chat process's composition over an invented window.
    @MainActor
    private struct SyntheticChat {
        let store: SQLiteLivingMemoryStore
        let tools: AutomationTools
        let cycle: TurnCycle

        init(
            knowledge: URL, file: URL, action: ActionCase? = nil,
            bundleID: String = "test.synthetic.mixer",
            windowTitle: String = "Synthetic New Paths",
            visibleLabels: [String]? = nil
        ) throws {
            store = try SQLiteLivingMemoryStore(file: file)
            let brain = BrainMemory(store: InMemoryKnowledgeStore(), clock: { Date() })
            let session = SyntheticWindowSession(
                intake: SceneIntake(brain: brain, livingMemory: store),
                bundleID: bundleID, windowTitle: windowTitle,
                labels: visibleLabels ?? action.map { [$0.target] } ?? ["Bus", "All Busses", "Inputs"]
            )
            if let action {
                session.descriptions[action.target] = "synthetic \(action.verb) target"
                if action.verb == "set_toggle" { session.toggleStates[action.target] = .off }
                if case .click(let click) = action.step {
                    let effect: ClickEvidence.Effect = switch click.opens {
                        case .menu             : .menuOpened(items: ["New", "Open", "Save As"])
                        case .window(let title): .windowOpened(title: title)
                    }
                    session.clickEffects[action.target] = [click.gesture: effect]
                }
            } else {
                session.captions = ["Tabs:", "Filter:"]
                session.descriptions = [
                    "Bus": "selected tab",
                    "All Busses": "dropdown filter of the Bus tab; its menu offers All Busses, Output Busses, Input Busses",
                    "Inputs": "tab",
                ]
            }
            tools = AutomationTools(session: session)
            cycle = TurnCycle(tools: tools, livingMemory: store)
        }

        struct Run {
            let sessionID: String?
            let replies: [String]
            let tools: [String]
            let requests: [(String, JSONValue)]
            let responses: [(String, JSONValue)]
        }

        /// One provider turn in a new conversation against the synthetic tools, drained before return.
        func run(_ provider: ChatProvider, cli: URL, bridge: String, prompt: String, root: URL) async throws -> Run {
            let names = NameLog()
            let definitions = AutomationTools.definitions.filter {
                SyntheticProviderTests.syntheticTools.contains($0["name"].string ?? "")
            }
            let router = MCPRouter(tools: definitions) { [tools] name, arguments in
                names.values.append(name)
                names.requests.append((name, arguments))
                let response = try await tools.call(name, arguments)
                names.responses.append((name, response))
                return response
            }
            let host = LocalMCPHost(router: router)
            let endpoint = try await host.start()
            defer { host.stop() }
            let connection = root.appendingPathComponent("connection-\(UUID().uuidString).json")
            try JSONEncoder().encode(endpoint).write(to: connection)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connection.path)
            let workspace = root.appendingPathComponent("Workspace-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let turn = ProviderTurn(
                provider: provider, model: provider == .claude ? "sonnet" : nil, sessionID: nil, prompt: prompt,
                instructions: SyntheticProviderTests.syntheticInstructions, bridgeExecutable: bridge,
                connectionFile: connection.path, workingDirectory: workspace.path
            )
            var sessionID: String?
            var replies: [String] = []
            try await CLIProvider().run(turn, executable: cli) { event in
                if case .session(let id) = event { sessionID = id }
                if case .assistant(let text) = event { replies.append(text) }
            }
            await router.drain()
            return Run(sessionID: sessionID, replies: replies, tools: names.values,
                       requests: names.requests, responses: names.responses)
        }
    }

    /// NameLog collects the tool names the router dispatched, on the main actor.
    @MainActor
    private final class NameLog {
        var values: [String] = []
        var requests: [(String, JSONValue)] = []
        var responses: [(String, JSONValue)] = []
    }

    private func executable(_ name: String) -> URL? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let file = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }
}

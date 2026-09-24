import ChatCore
import AutomationMCP
import CLIProviders
import Foundation
import LocalMCP
import Memory
import SQLiteLivingMemory
import Testing

/// SyntheticProviderTests contact the user's signed-in providers only when explicitly enabled.
/// The MCP host returns fixed invented data and has no dependency on AppKit, perception or Driver.
@Suite("Signed-in providers with synthetic MCP data")
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

    private let learning = "Seleziona Output Busses nel filtro della scheda Bus e verifica il nuovo valore. "
        + "Fermati se il controllo non è univoco."
    private let recalling = "Seleziona Output Busses nel filtro della scheda Bus in Synthetic Mixer. Prima dimmi se "
        + "hai un’esperienza verificata che può aiutare; poi osserva la finestra attuale e agisci solo se il "
        + "controllo è presente."

    /// The only tools the synthetic server offers: none of them reads a real application or window.
    private static let syntheticTools: Set<String> = ["open_session", "observe", "select"]

    private static let syntheticInstructions = ChatInstructions.standard + """

    This is a synthetic integration test with invented data. The only mecum tools here are open_session,
    observe and select: status and windows do not exist, so skip them. The application is "Synthetic Mixer".
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

        init(knowledge: URL, file: URL) throws {
            store = try SQLiteLivingMemoryStore(file: file)
            let brain = BrainMemory(store: InMemoryKnowledgeStore(), clock: { Date() })
            let session = SyntheticWindowSession(intake: SceneIntake(brain: brain, livingMemory: store),
                                                 bundleID: "test.synthetic.mixer", windowTitle: "Synthetic New Paths",
                                                 labels: ["Bus", "All Busses", "Inputs"])
            session.captions = ["Tabs:", "Filter:"]
            session.descriptions = [
                "Bus": "selected tab",
                "All Busses": "dropdown filter of the Bus tab; its menu offers All Busses, Output Busses, Input Busses",
                "Inputs": "tab",
            ]
            tools = AutomationTools(session: session)
            cycle = TurnCycle(tools: tools, livingMemory: store)
        }

        struct Run {
            let sessionID: String?
            let replies: [String]
            let tools: [String]
        }

        /// One provider turn in a new conversation against the synthetic tools, drained before return.
        func run(_ provider: ChatProvider, cli: URL, bridge: String, prompt: String, root: URL) async throws -> Run {
            let names = NameLog()
            let definitions = AutomationTools.definitions.filter {
                SyntheticProviderTests.syntheticTools.contains($0["name"].string ?? "")
            }
            let router = MCPRouter(tools: definitions) { [tools] name, arguments in
                names.values.append(name)
                return try await tools.call(name, arguments)
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
            return Run(sessionID: sessionID, replies: replies, tools: names.values)
        }
    }

    /// NameLog collects the tool names the router dispatched, on the main actor.
    @MainActor
    private final class NameLog {
        var values: [String] = []
    }

    private func executable(_ name: String) -> URL? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let file = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }
}

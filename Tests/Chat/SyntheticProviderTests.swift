import ChatCore
import AutomationMCP
import CLIProviders
import Foundation
import LocalMCP
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

    private func executable(_ name: String) -> URL? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let file = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }
}

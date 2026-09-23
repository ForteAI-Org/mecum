import ChatCore
import Foundation

/// ProviderInvocation builds argv without a shell. Only Mecum's MCP tools are authorized for Claude;
/// Codex runs read-only with shell tools disabled and only the explicitly supplied MCP configuration.
public struct ProviderInvocation: Sendable {
    public let arguments: [String]
    public let standardInput: String

    public init(_ turn: ProviderTurn) throws {
        standardInput = turn.prompt
        let bridgeArguments = ["mcp-bridge", "--connection", turn.connectionFile]
        var arguments: [String]
        switch turn.provider {
        case .claude:
            let config: [String: Any] = ["mcpServers": ["mecum": [
                "command": turn.bridgeExecutable, "args": bridgeArguments
            ]]]
            let encoded = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            arguments = ["-p", "--output-format", "stream-json", "--verbose",
                         "--strict-mcp-config", "--mcp-config", String(decoding: encoded, as: UTF8.self),
                         "--tools", "", "--allowedTools", "mcp__mecum__*",
                         "--permission-mode", "dontAsk", "--setting-sources", "",
                         "--disable-slash-commands", "--no-chrome",
                         "--append-system-prompt", turn.instructions]
            if let session = turn.sessionID { arguments += ["--resume", session] }
        case .codex:
            let command = try Self.quote(turn.bridgeExecutable)
            let args = try bridgeArguments.map(Self.quote).joined(separator: ",")
            let server = "{command=\(command),args=[\(args)],required=true,tool_timeout_sec=120,"
                + "default_tools_approval_mode=\"approve\"}"
            arguments = ["exec", "--ignore-user-config", "--json", "--skip-git-repo-check",
                         "-C", turn.workingDirectory, "-s", "read-only",
                         "-c", "approval_policy=\"never\"",
                         "-c", "features.shell_tool=false", "-c", "features.unified_exec=false",
                         "-c", "features.apps=false", "-c", "features.plugins=false",
                         "-c", "features.computer_use=false", "-c", "features.browser_use=false",
                         "-c", "features.view_image=false", "-c", "features.image_generation=false",
                         "-c", "web_search=\"disabled\"",
                         "-c", "developer_instructions=\(try Self.quote(turn.instructions))",
                         "-c", "mcp_servers.mecum=\(server)"]
            if let model = turn.model { arguments += ["--model", model] }
            if let effort = turn.effort { arguments += ["-c", "model_reasoning_effort=\(try Self.quote(effort))"] }
            if let session = turn.sessionID { arguments += ["resume", session] }
            arguments += ["-"]
        }
        if turn.provider == .claude, let model = turn.model { arguments += ["--model", model] }
        // Haiku has no effort levels, so the flag is left out for it, as ClaudeCLIClient does.
        if turn.provider == .claude, let effort = turn.effort, turn.model?.contains("haiku") != true {
            arguments += ["--effort", effort]
        }
        self.arguments = arguments
    }

    private static func quote(_ text: String) throws -> String {
        // TOML accepts JSON string escapes except escaped slashes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(text), as: UTF8.self)
    }
}

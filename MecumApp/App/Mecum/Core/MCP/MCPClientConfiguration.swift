import Foundation
import LocalMCP

/// MCPClientConfiguration renders installation data without including the local credential itself.
struct MCPClientConfiguration {
    let executable: URL
    let connection: URL
    private var arguments: [String] { ["mcp-bridge", "--connection", connection.path] }

    var json: String {
        let value = JSONValue.object(["mcpServers": .object(["mecum": .object([
            "command": .string(executable.path), "args": .array(arguments.map(JSONValue.string))
        ])])])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch { return "Could not encode MCP configuration: \(error)" }
    }

    var codexCommand: String { "codex mcp add mecum -- " + invocation }
    var claudeCommand: String { "claude mcp add --scope user --transport stdio mecum -- " + invocation }
    var invocation: String { ([executable.path] + arguments).map(Self.quote).joined(separator: " ") }

    private static func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

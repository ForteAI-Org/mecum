import BrowserMCP
import LocalMCP

/// Opens a synthetic tab using only references returned by the same tool host.
@MainActor
func browserTestContext(_ tools: BrowserTools) async throws -> [String: JSONValue] {
    let connected = try await tools.call("browser_connect", .object(["profile": .string("automation")]))["structuredContent"]
    let opened = try await tools.call("browser_open", .object(["connection": connected["id"], "url": .string("about:blank")]))["structuredContent"]
    return ["connection": connected["id"], "tab": opened["id"], "snapshot": opened["observation"]["id"], "ref": .string("e1")]
}

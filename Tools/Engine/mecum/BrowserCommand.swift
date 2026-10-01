import BrowserMCP
import ChromeBrowser
import Foundation
import LocalMCP

/// BrowserCommand runs one native browser engine as JSONL or MCP stdio, retaining references between calls.
@MainActor
enum BrowserCommand {
    static let usage = """
    mecum browser [--mcp] [--automation-profile /absolute/profile/path]
      JSONL input: {"tool":"browser_connect","arguments":{"profile":"current"}}
      Further calls use connection/tab/snapshot/ref IDs from earlier responses.
      Use --mcp for a standard MCP stdio server with the same browser_* tools.
      EOF releases debugging and leaves Chrome running. No cookies or profiles are copied.
    """

    static func run(arguments: [String]) async throws {
        if arguments == ["--help"] || arguments == ["help"] { print(usage); return }
        var remaining = arguments
        let mcp = remaining.first == "--mcp"
        if mcp { remaining.removeFirst() }
        var configuration = ChromeConfiguration.standard()
        if remaining.count == 2, remaining[0] == "--automation-profile", remaining[1].hasPrefix("/") {
            configuration = ChromeConfiguration(executable: configuration.executable,
                currentProfile: configuration.currentProfile, automationProfile: URL(fileURLWithPath: remaining[1]))
        } else if !remaining.isEmpty { throw UsageError.missing(usage) }
        let tools = BrowserTools(browser: ChromeBrowser(configuration: configuration))
        let router = MCPRouter(tools: BrowserTools.definitions, instructions: BrowserTools.instructions) { name, args in try await tools.call(name, args) }
        if !mcp { FileHandle.standardError.write(Data((usage + "\n").utf8)) }
        do {
            while let line = await Task.detached(operation: { readLine() }).value {
                if line.isEmpty { continue }
                var response: JSONValue?
                do {
                    guard line.utf8.count <= 131_072 else { throw UsageError.missing("JSONL request at most 128 KiB") }
                    let request = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                    if mcp { response = await router.handle(request) }
                    else {
                        guard let tool = request["tool"].string else { throw UsageError.missing("JSONL tool name") }
                        response = try await tools.call(tool, request["arguments"])
                    }
                } catch { response = MCPRouter.failureResult(error) }
                if let response {
                    var data = try JSONEncoder().encode(response)
                    data.append(10)
                    try FileHandle.standardOutput.write(contentsOf: data)
                }
            }
            try await tools.shutdown()
        } catch {
            do { try await tools.shutdown() } catch { FileHandle.standardError.write(Data("Browser cleanup failed: \(error)\n".utf8)) }
            throw error
        }
    }
}

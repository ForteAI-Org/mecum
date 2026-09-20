import Foundation

/// MCPRouter implements the stdio MCP request surface. Tool execution is injected and serialized:
/// a concurrent caller gets a busy error rather than interleaving application effects.
@MainActor
public final class MCPRouter {
    public typealias Call = @MainActor (String, JSONValue) async throws -> JSONValue
    private let tools: [JSONValue]
    private let call: Call
    private var isBusy = false
    private var activeCall: Task<JSONValue, any Error>?
    public private(set) var isAcceptingTools = true

    public init(tools: [JSONValue], call: @escaping Call) {
        self.tools = tools
        self.call = call
    }

    public func pause() {
        isAcceptingTools = false
        activeCall?.cancel()
    }
    public func resume() { isAcceptingTools = true }

    /// Waits for an in-flight call before the owner releases Seat resources.
    public func drain() async {
        while isBusy { try? await Task.sleep(for: .milliseconds(25)) }
    }

    public func handle(_ request: JSONValue) async -> JSONValue? {
        let id = request["id"]
        guard request["jsonrpc"].string == "2.0", let method = request["method"].string else {
            return error(id, -32600, "Invalid JSON-RPC request.")
        }
        if id == .null { return nil }
        do {
            let result: JSONValue
            switch method {
            case "initialize":
                let requested = request["params"]["protocolVersion"].string ?? ""
                let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                result = .object([
                    "protocolVersion": .string(supported.contains(requested) ? requested : "2025-11-25"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("mecum"), "version": .string("0.1.0")]),
                    "instructions": .string("Use windows, then open_session. All actions stay on the background Seat. "
                                            + "Observe after resuming a conversation. Never repeat an unverified action blindly.")
                ])
            case "ping": result = .object([:])
            case "tools/list": result = .object(["tools": .array(tools)])
            case "tools/call":
                guard isAcceptingTools else { return error(id, -32000, "Mecum is stopping. No further actions accepted.") }
                guard !isBusy else { return error(id, -32000, "Another Mecum operation is still running. Observe when it finishes.") }
                guard let name = request["params"]["name"].string,
                      tools.contains(where: { $0["name"].string == name }) else {
                    return error(id, -32602, "Unknown tool.")
                }
                isBusy = true
                defer { isBusy = false; activeCall = nil }
                do {
                    let task = Task { try await call(name, request["params"]["arguments"]) }
                    activeCall = task
                    result = try await task.value
                } catch {
                    result = Self.toolResult(.object([
                        "status": .string("error"),
                        "message": .string(String(describing: error)),
                        "guidance": .string("Effects may be partial. Observe before deciding the next action; do not replay automatically.")
                    ]), isError: true)
                }
            default: return error(id, -32601, "Method not found: \(method)")
            }
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        }
    }

    public static func toolResult(_ value: JSONValue, isError: Bool = false) -> JSONValue {
        let text: String
        do { text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        catch { text = "Could not encode tool result: \(error)" }
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": value, "isError": .bool(isError)
        ])
    }

    private func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}

import Foundation
import ModelTransports

/// BrowserProbeTransport is a deterministic local model substitute; no provider account is contacted.
nonisolated struct BrowserProbeTransport: ModelTransport {
    let page: URL
    var articleCount: Int? = nil
    var targetRole = "button"
    var targetName = "Run"
    var resultRole = "button"
    var resultName = "Done"
    var disconnectOnCompletion = true
    var streaming: StreamingSupport { .incremental }

    func capabilities() async throws -> ModelCapabilities { ModelCapabilities(supportsTools: true) }
    func complete(prompt: String, schema: Data, timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("Use the scripted tool conversation.")
    }
    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval) throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let results = messages.filter { $0.role == .tool }
        guard !results.contains(where: \.isError) else {
            throw NSError(domain: "BrowserProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: results.last?.text ?? "Tool failed"])
        }
        func result(_ name: String) throws -> [String: Any] {
            guard let text = results.last(where: { $0.call?.name == name })?.text else { return [:] }
            // Compact observations have one metadata JSON line followed by readable node rows.
            let header = text.components(separatedBy: "\n")[0]
            return try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any] ?? [:]
        }
        let connection = try result("browser_connect")["id"] as? String ?? ""
        let tab = try result("browser_open")["id"] as? String ?? ""
        var name: String?
        var args: [String: Any] = ["connection": connection, "tab": tab]
        switch results.last?.call?.name {
        case nil:
            name = "browser_connect"; args = ["profile": "automation"]
        case "browser_connect":
            name = "browser_open"; args = ["connection": connection, "url": page.absoluteString]
        case "browser_open", "browser_click", "browser_snapshot":
            let previous = results.last?.call?.name ?? ""
            if let articleCount {
                name = "browser_collect"; args["count"] = articleCount; args["maxScrolls"] = 12
                break
            }
            let text = results.last?.text ?? ""
            let observation = previous == "browser_snapshot" ? text : text.components(separatedBy: "\nobservation:\n").last ?? ""
            let lines = observation.components(separatedBy: "\n")
            let snapshot = try JSONSerialization.jsonObject(with: Data((lines.first ?? "{}").utf8)) as? [String: Any] ?? [:]
            if lines.contains(where: { $0.contains(" \(resultRole) \"\(resultName)\"") }) {
                name = disconnectOnCompletion ? "browser_close" : nil
            } else if let row = lines.first(where: { $0.contains(" \(targetRole) \"\(targetName)\"") }), let end = row.firstIndex(of: "]") {
                name = "browser_click"; args["snapshot"] = snapshot["id"]; args["ref"] = String(row[row.index(after: row.startIndex)..<end])
            } else if results.filter({ $0.call?.name == "browser_snapshot" }).count < 3 {
                name = "browser_snapshot"
            } else { throw NSError(domain: "BrowserProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Synthetic control was not observed"]) }
        case "browser_collect":
            let collected = try result("browser_collect")
            guard (collected["items"] as? [[String: Any]])?.count == articleCount,
                  collected["stopReason"] as? String == "countReached" else {
                throw NSError(domain: "BrowserProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Article collection was incomplete"])
            }
            name = "browser_close"
        case "browser_close": name = "browser_disconnect"; args = ["connection": connection]
        default: name = nil
        }
        let call = try name.map { ToolCall(id: UUID().uuidString, name: $0, arguments: try JSONSerialization.data(withJSONObject: args)) }
        return AsyncThrowingStream { continuation in
            if let call { continuation.yield(.toolCall(call)) }
            else { continuation.yield(.delta("Synthetic Chrome interaction verified.")) }
            continuation.yield(.completed(ModelUsage(inputTokens: nil, outputTokens: nil, duration: .zero)))
            continuation.finish()
        }
    }
}

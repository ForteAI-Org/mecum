import ChatCore
import Foundation

/// ProviderEventDecoder translates documented JSONL events, leaving provider internals outside ChatCore.
public struct ProviderEventDecoder {
    private let provider: ChatProvider
    private var hasAssistant = false

    public init(provider: ChatProvider) { self.provider = provider }

    public mutating func decode(_ line: Data) throws -> [ProviderEvent] {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        var events: [ProviderEvent] = []
        switch provider {
        case .claude:
            if let session = object["session_id"] as? String { events.append(.session(session)) }
            if object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "text" {
                    if let text = block["text"] as? String, !text.isEmpty {
                        hasAssistant = true
                        events.append(.assistant(text))
                    }
                }
            }
            if object["type"] as? String == "result" {
                if object["is_error"] as? Bool == true {
                    let errors = (object["errors"] as? [String])?.joined(separator: "\n")
                    events.append(.failure(errors ?? object["result"] as? String ?? "Claude turn failed."))
                } else {
                    if !hasAssistant, let text = object["result"] as? String, !text.isEmpty {
                        events.append(.assistant(text))
                    }
                    events.append(.completed)
                }
            }
        case .codex:
            switch object["type"] as? String {
            case "thread.started":
                if let session = object["thread_id"] as? String { events.append(.session(session)) }
            case "item.completed":
                if let item = object["item"] as? [String: Any],
                   item["type"] as? String == "agent_message", let text = item["text"] as? String {
                    events.append(.assistant(text))
                }
            case "turn.completed": events.append(.completed)
            case "turn.failed":
                let error = object["error"] as? [String: Any]
                events.append(.failure(error?["message"] as? String ?? "Codex turn failed."))
            case "error": events.append(.failure(object["message"] as? String ?? "Codex error."))
            default: break
            }
        }
        return events
    }
}

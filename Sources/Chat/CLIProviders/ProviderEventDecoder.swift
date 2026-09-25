import ChatCore
import Foundation

/// ProviderEventDecoder translates documented JSONL events, leaving provider internals outside ChatCore.
/// One decoder reads one turn: Claude's usage names the model from the turn's `init` and the limits
/// from its latest `rate_limit_event`.
public struct ProviderEventDecoder {
    private let provider: ChatProvider
    private var hasAssistant = false
    private var model: String?
    private var rateLimits: [ProviderUsage.RateLimit] = []

    public init(provider: ChatProvider) { self.provider = provider }

    public mutating func decode(_ line: Data) throws -> [ProviderEvent] {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        var events: [ProviderEvent] = []
        switch provider {
        case .claude:
            if let session = object["session_id"] as? String { events.append(.session(session)) }
            if object["type"] as? String == "system", object["subtype"] as? String == "init" {
                model = object["model"] as? String
            }
            if object["type"] as? String == "rate_limit_event", let info = object["rate_limit_info"] as? [String: Any] {
                rateLimits = Self.claudeLimits(info)
            }
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
                if let usage = claudeUsage(object) { events.append(.usage(usage)) }
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
            case "turn.completed":
                // Codex counts the whole session so far, not the turn.
                if let usage = object["usage"] as? [String: Any] {
                    let count = { (key: String) in usage[key] as? Int ?? 0 }
                    let tokens = ProviderUsage.Tokens(
                        input: count("input_tokens"), cacheReads: count("cached_input_tokens"),
                        cacheWrites: count("cache_write_input_tokens"), output: count("output_tokens"),
                        reasoning: count("reasoning_output_tokens"))
                    events.append(.usage(ProviderUsage(tokens: tokens, isSessionTotal: true)))
                }
                events.append(.completed)
            case "turn.failed":
                let error = object["error"] as? [String: Any]
                events.append(.failure(error?["message"] as? String ?? "Codex turn failed."))
            case "error": events.append(.failure(object["message"] as? String ?? "Codex error."))
            default: break
            }
        }
        return events
    }

    /// The turn's usage from a Claude `result`: `usage` for the turn, its last iteration (one per API
    /// call) for the context left after it, and the window of the model `init` named from `modelUsage`.
    private func claudeUsage(_ result: [String: Any]) -> ProviderUsage? {
        guard let usage = result["usage"] as? [String: Any] else { return nil }
        let models = result["modelUsage"] as? [String: [String: Any]] ?? [:]
        let named = model ?? (models.count == 1 ? models.keys.first : nil)
        let entry = named.flatMap { models[$0] } ?? (models.count == 1 ? models.values.first : nil)
        let last = (usage["iterations"] as? [[String: Any]])?.last.map(Self.claudeTokens)
        return ProviderUsage(tokens: Self.claudeTokens(usage), model: named,
                             contextTokens: last.map { $0.input + $0.output },
                             contextWindow: entry?["contextWindow"] as? Int, rateLimits: rateLimits)
    }

    /// Claude counts cache reads and writes apart from `input_tokens`; `input` here includes them.
    private static func claudeTokens(_ usage: [String: Any]) -> ProviderUsage.Tokens {
        let count = { (key: String) in usage[key] as? Int ?? 0 }
        let details = usage["output_tokens_details"] as? [String: Any]
        return ProviderUsage.Tokens(
            input: count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens"),
            cacheReads: count("cache_read_input_tokens"), cacheWrites: count("cache_creation_input_tokens"),
            output: count("output_tokens"), reasoning: details?["thinking_tokens"] as? Int ?? 0)
    }

    /// Every window of a `rate_limit_event`, by name, or the one it names when it lists none.
    private static func claudeLimits(_ info: [String: Any]) -> [ProviderUsage.RateLimit] {
        func limit(_ window: String, _ values: [String: Any]?) -> ProviderUsage.RateLimit? {
            guard let used = values?["utilization"] as? Double else { return nil }
            let resetsAt = (values?["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            return ProviderUsage.RateLimit(window: window, usedFraction: used, resetsAt: resetsAt)
        }
        if let windows = info["unifiedWindows"] as? [String: [String: Any]] {
            return windows.keys.sorted().compactMap { limit($0, windows[$0]) }
        }
        return (info["rateLimitType"] as? String).flatMap { limit($0, info) }.map { [$0] } ?? []
    }
}

import Foundation

/// Claude through the Messages API, structured for one request and streamed
/// for a conversation. Thinking stays adaptive (the default on current
/// models); `effort` is the only knob.
struct AnthropicClient: ModelTransport {
    let model: String
    let effort: ReasoningEffort
    let apiKey: String
    var streaming: StreamingSupport { .incremental }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func complete(prompt: String, schema: Data, timeout: TimeInterval)
        async throws -> (text: String, usage: ModelUsage) {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.anthropic) }
        let schemaObject = try JSONSerialization.jsonObject(with: schema)
        // Haiku 4.5 rejects `effort`; every other current model takes it.
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": schemaObject]]
        if !model.contains("haiku") { outputConfig["effort"] = effort.rawValue }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "output_config": outputConfig,
            "messages": [["role": "user", "content": prompt]],
        ]
        let (json, elapsed) = try await HTTPTransport.postJSON(Self.endpoint, headers: headers,
                                                               body: body, timeout: timeout)

        if let stop = json["stop_reason"] as? String, stop == "refusal" || stop == "max_tokens" {
            throw ProviderError.badResponse("stop_reason \(stop)")
        }
        let content = json["content"] as? [[String: Any]] ?? []
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw ProviderError.badResponse("no text block")
        }
        let usage = json["usage"] as? [String: Any]
        return (text, ModelUsage(inputTokens: usage?["input_tokens"] as? Int,
                                 outputTokens: usage?["output_tokens"] as? Int,
                                 duration: elapsed))
    }

    func converse(_ messages: [TurnMessage], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.anthropic) }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "messages": messages.filter { $0.role != .system }
                .map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] },
        ]
        // The Messages API takes the system instruction beside the turns, not
        // as one of them.
        let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = system }
        if !model.contains("haiku") { body["output_config"] = ["effort": effort.rawValue] }
        let request = try HTTPTransport.request(Self.endpoint, headers: headers, body: body, timeout: timeout)
        return HTTPTransport.stream(request,
                                    assembler: TurnAssembler(format: .serverSentEvents, decode: Self.decode))
    }

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }

    /// One server-sent event of a Messages stream. The counts arrive in their
    /// own events: the input with the message's start, the output with its end.
    static func decode(_ payload: Data, progress: inout TurnProgress) throws -> String? {
        guard let event = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        switch type {
        case "message_start":
            let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
            progress.inputTokens = usage?["input_tokens"] as? Int
        case "content_block_delta":
            // A thinking delta carries "thinking" and no "text": only the
            // answer's own text is part of the turn.
            return (event["delta"] as? [String: Any])?["text"] as? String
        case "message_delta":
            progress.outputTokens = (event["usage"] as? [String: Any])?["output_tokens"] as? Int
        case "message_stop":
            progress.isFinished = true
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
            throw ProviderError.badResponse(message ?? "error event")
        default:
            break
        }
        return nil
    }
}

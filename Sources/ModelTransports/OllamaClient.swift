import Foundation

/// A local Ollama model through `/api/chat`: a JSON schema `format` for one
/// request, newline-delimited events for a conversation, with tools or
/// without. Tokens per second come from Ollama's own eval counters.
///
/// A model being pulled says nothing about what it can do (§7.2), and Ollama
/// refuses a request that asks a model for more, so every request first asks
/// `/api/show`. `think` goes only to a model that thinks: its own level name
/// for the effort when it names levels (gpt-oss), otherwise off for effort
/// `low` and on for anything else. Tools go only where the caller hands them,
/// which the caller decides from `capabilities()`.
struct OllamaClient: ModelTransport {
    let model: String
    let effort: ReasoningEffort
    let settings: ProviderSettings
    var streaming: StreamingSupport { .incremental }
    var requestTimeout: TimeInterval { settings.ollamaTimeoutSeconds }

    func complete(prompt: String, schema: Data, timeout: TimeInterval)
        async throws -> (text: String, usage: ModelUsage) {
        var body = try requestBody(messages: [TurnMessage(role: .user, text: prompt)], tools: [], stream: false,
                                   show: try await show())
        body["format"] = try JSONSerialization.jsonObject(with: schema)
        let (json, elapsed) = try await HTTPTransport.postJSON(try Self.endpoint(settings.ollamaHost, "/api/chat"),
                                                               headers: [:], body: body, timeout: timeout)
        guard let text = (json["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
            throw ProviderError.badResponse("empty message")
        }
        // eval_duration is nanoseconds of generation; it is the honest tok/s denominator.
        let generated = (json["eval_duration"] as? Int).map { Duration.nanoseconds($0) } ?? elapsed
        return (text, ModelUsage(inputTokens: json["prompt_eval_count"] as? Int,
                                 outputTokens: json["eval_count"] as? Int,
                                 duration: generated))
    }

    func converse(_ messages: [TurnMessage], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        try converse(messages, tools: [], timeout: timeout)
    }

    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let url = try Self.endpoint(settings.ollamaHost, "/api/chat")
        // The body depends on what `/api/show` answers, so it is built as the stream starts.
        return HTTPTransport.stream({
            let body = try requestBody(messages: messages, tools: tools, stream: true, show: try await show())
            return try HTTPTransport.request(url, headers: [:], body: body, timeout: timeout)
        }, assembler: TurnAssembler(format: .newlineDelimitedJSON, decode: Self.decode))
    }

    func capabilities() async throws -> ModelCapabilities {
        Self.capabilities(show: try await show())
    }

    /// The `/api/chat` body for `messages`, with `tools` when there are any
    /// and `think` as `show`, the model's `/api/show` answer, allows it.
    func requestBody(messages: [TurnMessage], tools: [ToolDefinition], stream: Bool,
                     show: [String: Any]) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "keep_alive": "5m",
            "options": [
                "temperature": settings.ollamaTemperature,
                "top_p": settings.ollamaTopP,
                "top_k": settings.ollamaTopK,
                "presence_penalty": settings.ollamaPresencePenalty,
                "num_ctx": settings.ollamaContextTokens,
                "num_predict": settings.ollamaMaxOutputTokens,
            ],
            "messages": try messages.map(Self.message),
        ]
        if let think = Self.think(effort, show: show) { body["think"] = think }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool in
                ["type": "function",
                 "function": ["name": tool.name, "description": tool.description,
                              "parameters": try JSONSerialization.jsonObject(with: tool.parameters)]]
            }
        }
        return body
    }

    /// One message in Ollama's shape: an assistant's calls go back with their
    /// arguments as objects, and a tool's answer names its tool, which is how
    /// Ollama matches it to the call. Ollama has no error flag: the text says so.
    static func message(_ message: TurnMessage) throws -> [String: Any] {
        var mapped: [String: Any] = ["role": message.role.rawValue, "content": message.text]
        if !message.toolCalls.isEmpty {
            mapped["tool_calls"] = try message.toolCalls.map { call in
                ["type": "function",
                 "function": ["name": call.name, "arguments": try JSONSerialization.jsonObject(with: call.arguments)]]
            }
        }
        if let call = message.call { mapped["tool_name"] = call.name }
        return mapped
    }

    /// The `think` value for `effort`, or nil to leave the field out. A model
    /// whose `capabilities` lack `thinking` refuses the field. `thinking.values`
    /// names what the model accepts: level strings (gpt-oss), which take the
    /// effort's own name, or booleans, off for `low` and on for anything else.
    /// A value the model does not list is left out, so its default applies; a
    /// server that lists no values is sent the boolean.
    static func think(_ effort: ReasoningEffort, show: [String: Any]) -> Any? {
        guard (show["capabilities"] as? [String])?.contains("thinking") == true else { return nil }
        let isOn = effort != .low
        guard let values = (show["thinking"] as? [String: Any])?["values"] as? [Any] else { return isOn }
        let levels = values.compactMap { $0 as? String }
        if !levels.isEmpty { return levels.contains(effort.rawValue) ? effort.rawValue : nil }
        return values.contains { $0 as? Bool == isOn } ? isOn : nil
    }

    /// What `/api/show`'s `capabilities` list says the model can do.
    static func capabilities(show: [String: Any]) -> ModelCapabilities {
        let listed = Set(show["capabilities"] as? [String] ?? [])
        return ModelCapabilities(supportsTools: listed.contains("tools"),
                                 supportsThinking: listed.contains("thinking"),
                                 supportsVision: listed.contains("vision"))
    }

    /// The model's `/api/show` answer. A model the server does not have fails
    /// here, in Ollama's own words.
    private func show() async throws -> [String: Any] {
        try await HTTPTransport.postJSON(try Self.endpoint(settings.ollamaHost, "/api/show"), headers: [:],
                                         body: ["model": model], timeout: 15).json
    }

    /// Models the local server has pulled.
    static func models(host: String) async throws -> [String] {
        let json = try await HTTPTransport.getJSON(try endpoint(host, "/api/tags"))
        let models = json["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    private static func endpoint(_ host: String, _ path: String) throws -> URL {
        let base = host.hasSuffix("/") ? String(host.dropLast()) : host
        guard let url = URL(string: base + path), url.scheme != nil else {
            throw ProviderError.badResponse("Ollama host \"\(host)\" is not a URL")
        }
        return url
    }

    /// One line of a streamed `/api/chat`. The counts, the generation time and
    /// the `done_reason` arrive only on the line that declares the turn done;
    /// only `stop` is a whole answer, and `length` is the output limit. A turn
    /// that called tools also ends with `stop`. Tool calls arrive whole, their
    /// arguments an object. Ollama's documented shape shows no id, but current
    /// servers send one, which is kept; a call without one is numbered in the
    /// order it arrived. `message.thinking` is the model's reasoning and never
    /// part of the answer.
    static func decode(_ payload: Data, progress: inout TurnProgress) throws -> String? {
        guard let event = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        if let error = event["error"] as? String { throw ProviderError.badResponse(error) }
        let message = event["message"] as? [String: Any]
        for call in message?["tool_calls"] as? [[String: Any]] ?? [] {
            let function = call["function"] as? [String: Any] ?? [:]
            guard let name = function["name"] as? String,
                  let arguments = (function["arguments"] ?? [String: Any]()) as? [String: Any] else {
                throw ProviderError.badResponse("a tool call without a name or with arguments that are not an object")
            }
            progress.toolCalls.append(ToolCall(
                id: call["id"] as? String ?? "call_\(progress.toolCalls.count)",
                name: name,
                arguments: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)))
        }
        if event["done"] as? Bool == true {
            progress.isFinished = true
            progress.recordStop(event["done_reason"] as? String, wholeAnswerReasons: ["stop"])
            progress.inputTokens = event["prompt_eval_count"] as? Int
            progress.outputTokens = event["eval_count"] as? Int
            progress.generated = (event["eval_duration"] as? Int).map { Duration.nanoseconds($0) }
        }
        return message?["content"] as? String
    }
}

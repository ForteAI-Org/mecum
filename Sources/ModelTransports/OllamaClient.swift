import Foundation

/// A local Ollama model through `/api/chat`: a JSON schema `format` for one
/// request, newline-delimited events for a conversation. Effort `low` runs
/// with thinking off, anything else with thinking on. Tokens per second come
/// from Ollama's own eval counters.
struct OllamaClient: ModelTransport {
    let model: String
    let effort: ReasoningEffort
    let settings: ProviderSettings
    var streaming: StreamingSupport { .incremental }
    var requestTimeout: TimeInterval { settings.ollamaTimeoutSeconds }

    func complete(prompt: String, schema: Data, timeout: TimeInterval)
        async throws -> (text: String, usage: ModelUsage) {
        var body = requestBody(messages: [["role": "user", "content": prompt]], stream: false)
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
        let body = requestBody(messages: messages.map { ["role": $0.role.rawValue, "content": $0.text] },
                               stream: true)
        let request = try HTTPTransport.request(try Self.endpoint(settings.ollamaHost, "/api/chat"),
                                                headers: [:], body: body, timeout: timeout)
        return HTTPTransport.stream(request,
                                    assembler: TurnAssembler(format: .newlineDelimitedJSON, decode: Self.decode))
    }

    private func requestBody(messages: [[String: String]], stream: Bool) -> [String: Any] {
        [
            "model": model,
            "stream": stream,
            "think": effort != .low,
            "keep_alive": "5m",
            "options": [
                "temperature": settings.ollamaTemperature,
                "top_p": settings.ollamaTopP,
                "top_k": settings.ollamaTopK,
                "presence_penalty": settings.ollamaPresencePenalty,
                "num_ctx": settings.ollamaContextTokens,
                "num_predict": settings.ollamaMaxOutputTokens,
            ],
            "messages": messages,
        ]
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
    /// only `stop` is a whole answer, and `length` is the output limit.
    static func decode(_ payload: Data, progress: inout TurnProgress) throws -> String? {
        guard let event = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        if let error = event["error"] as? String { throw ProviderError.badResponse(error) }
        if event["done"] as? Bool == true {
            progress.isFinished = true
            progress.recordStop(event["done_reason"] as? String, wholeAnswerReasons: ["stop"])
            progress.inputTokens = event["prompt_eval_count"] as? Int
            progress.outputTokens = event["eval_count"] as? Int
            progress.generated = (event["eval_duration"] as? Int).map { Duration.nanoseconds($0) }
        }
        return (event["message"] as? [String: Any])?["content"] as? String
    }
}

import Foundation

/// A local Ollama model through `/api/chat` with a JSON schema `format`.
/// Effort `low` runs with thinking off, anything else with thinking on.
/// Tokens per second come from Ollama's own eval counters.
struct OllamaClient: ModelClient {
    let model: String
    let effort: ReasoningEffort
    let settings: ProviderSettings
    var schemaFlavor: PlanSchema.Flavor { .full }
    var prefersCompactPrompt: Bool { true }
    var requestTimeout: TimeInterval { settings.ollamaTimeoutSeconds }

    func plan(prompt: String, schema: Data, timeout: TimeInterval) async throws -> PlanReply {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": effort != .low,
            "keep_alive": "5m",
            "format": try JSONSerialization.jsonObject(with: schema),
            "options": [
                "temperature": settings.ollamaTemperature,
                "top_p": settings.ollamaTopP,
                "top_k": settings.ollamaTopK,
                "presence_penalty": settings.ollamaPresencePenalty,
                "num_ctx": settings.ollamaContextTokens,
                "num_predict": settings.ollamaMaxOutputTokens,
            ],
            "messages": [["role": "user", "content": prompt]],
        ]
        let (json, elapsed) = try await HTTPTransport.postJSON(try Self.endpoint(settings.ollamaHost, "/api/chat"),
                                                               headers: [:], body: body, timeout: timeout)
        guard let text = (json["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
            throw ProviderError.badResponse("empty message")
        }
        // eval_duration is nanoseconds of generation; it is the honest tok/s denominator.
        let generated = (json["eval_duration"] as? Int).map { Duration.nanoseconds($0) } ?? elapsed
        return PlanReply(plan: try HTTPTransport.decodePlan(text),
                         usage: ModelUsage(inputTokens: json["prompt_eval_count"] as? Int,
                                           outputTokens: json["eval_count"] as? Int,
                                           duration: generated))
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
}

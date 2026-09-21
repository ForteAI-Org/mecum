import Foundation

/// Claude through the Messages API with structured output. Thinking stays
/// adaptive (the default on current models); `effort` is the only knob.
struct AnthropicClient: ModelClient {
    let model: String
    let effort: ReasoningEffort
    let apiKey: String
    var schemaFlavor: PlanSchema.Flavor { .anthropic }

    func plan(prompt: String, schema: Data, timeout: TimeInterval) async throws -> PlanReply {
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
        let (json, elapsed) = try await HTTPTransport.postJSON(
            URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
            body: body, timeout: timeout)

        if let stop = json["stop_reason"] as? String, stop == "refusal" || stop == "max_tokens" {
            throw ProviderError.badResponse("stop_reason \(stop)")
        }
        let content = json["content"] as? [[String: Any]] ?? []
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw ProviderError.badResponse("no text block")
        }
        let usage = json["usage"] as? [String: Any]
        return PlanReply(plan: try HTTPTransport.decodePlan(text),
                         usage: ModelUsage(inputTokens: usage?["input_tokens"] as? Int,
                                           outputTokens: usage?["output_tokens"] as? Int,
                                           duration: elapsed))
    }
}

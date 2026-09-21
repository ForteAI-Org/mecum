import Foundation

/// Gemini through `generateContent` with a JSON response schema. Effort maps
/// to `thinkingLevel` on Gemini 3 models; older models ignore it.
struct GeminiClient: ModelClient {
    let model: String
    let effort: ReasoningEffort
    let apiKey: String
    var schemaFlavor: PlanSchema.Flavor { .gemini }

    func plan(prompt: String, schema: Data, timeout: TimeInterval) async throws -> PlanReply {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.gemini) }
        var generation: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": try JSONSerialization.jsonObject(with: schema),
        ]
        if model.contains("gemini-3") {
            generation["thinkingConfig"] = ["thinkingLevel": effort.rawValue]
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": generation,
        ]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let (json, elapsed) = try await HTTPTransport.postJSON(url, headers: ["x-goog-api-key": apiKey],
                                                               body: body, timeout: timeout)

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        guard let text = parts.compactMap({ $0["text"] as? String }).first else {
            let reason = candidates.first?["finishReason"] as? String ?? "no candidates"
            throw ProviderError.badResponse(reason)
        }
        let usage = json["usageMetadata"] as? [String: Any]
        return PlanReply(plan: try HTTPTransport.decodePlan(text),
                         usage: ModelUsage(inputTokens: usage?["promptTokenCount"] as? Int,
                                           outputTokens: usage?["candidatesTokenCount"] as? Int,
                                           duration: elapsed))
    }
}

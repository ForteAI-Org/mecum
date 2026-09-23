import Foundation

/// Gemini through `generateContent` with a JSON response schema, and through
/// `streamGenerateContent` for a conversation. Effort maps to `thinkingLevel`
/// on Gemini 3 models; older models ignore it.
struct GeminiClient: ModelTransport {
    let model: String
    let effort: ReasoningEffort
    let apiKey: String
    var streaming: StreamingSupport { .incremental }

    func complete(prompt: String, schema: Data, timeout: TimeInterval)
        async throws -> (text: String, usage: ModelUsage) {
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
        let (json, elapsed) = try await HTTPTransport.postJSON(try Self.endpoint(model, "generateContent"),
                                                               headers: headers, body: body, timeout: timeout)

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        guard let text = parts.compactMap({ $0["text"] as? String }).first else {
            let reason = candidates.first?["finishReason"] as? String ?? "no candidates"
            throw ProviderError.badResponse(reason)
        }
        let usage = json["usageMetadata"] as? [String: Any]
        return (text, ModelUsage(inputTokens: usage?["promptTokenCount"] as? Int,
                                 outputTokens: usage?["candidatesTokenCount"] as? Int,
                                 duration: elapsed))
    }

    func converse(_ messages: [TurnMessage], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.gemini) }
        var body: [String: Any] = [
            "contents": messages.filter { $0.role != .system }
                .map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] },
        ]
        let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        if model.contains("gemini-3") {
            body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": effort.rawValue]]
        }
        // Without alt=sse the streaming endpoint answers with one JSON array
        // instead of events, which is not a stream at all.
        let request = try HTTPTransport.request(try Self.endpoint(model, "streamGenerateContent?alt=sse"),
                                                headers: headers, body: body, timeout: timeout)
        return HTTPTransport.stream(request,
                                    assembler: TurnAssembler(format: .serverSentEvents, decode: Self.decode))
    }

    private var headers: [String: String] { ["x-goog-api-key": apiKey] }

    /// The key travels in a header and never in the URL: a query string is
    /// logged by every proxy on the way.
    private static func endpoint(_ model: String, _ method: String) throws -> URL {
        let base = "https://generativelanguage.googleapis.com/v1beta/models/"
        guard let url = URL(string: base + model + ":" + method) else {
            throw ProviderError.badResponse("model \"\(model)\" is not a URL path")
        }
        return url
    }

    /// One event of a `streamGenerateContent` stream. The usage block is resent
    /// with every chunk, so the last one read is the turn's own total. Any
    /// `finishReason` ends the turn, but only `STOP` is a whole answer.
    static func decode(_ payload: Data, progress: inout TurnProgress) throws -> String? {
        guard let event = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        if let usage = event["usageMetadata"] as? [String: Any] {
            progress.inputTokens = usage["promptTokenCount"] as? Int
            progress.outputTokens = usage["candidatesTokenCount"] as? Int
        }
        if let error = event["error"] as? [String: Any] {
            throw ProviderError.badResponse(error["message"] as? String ?? "error event")
        }
        guard let candidate = (event["candidates"] as? [[String: Any]])?.first else { return nil }
        if let reason = candidate["finishReason"] as? String {
            progress.isFinished = true
            progress.recordStop(reason, wholeAnswerReasons: ["STOP"])
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        // A part marked as thought is the model's reasoning, not its answer.
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
}

import Foundation

/// Gemini through `generateContent` with a JSON response schema, and through
/// `streamGenerateContent` for a conversation, with tools or without. Effort
/// maps to `thinkingLevel` on Gemini 3 models; older models ignore it.
///
/// Tools go as `parametersJsonSchema`, which takes a JSON Schema as it is;
/// `parameters` is an OpenAPI subset without `oneOf` or `const`. A tool turn
/// keeps its parts as a `TurnRecord`, because a function call's thought
/// signature must return inside the part it came in, and parts are sent back
/// as they streamed, never merged.
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
        try converse(messages, tools: [], timeout: timeout)
    }

    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.gemini) }
        let body = try requestBody(messages: messages, tools: tools)
        // Without alt=sse the streaming endpoint answers with one JSON array
        // instead of events, which is not a stream at all.
        let request = try HTTPTransport.request(try Self.endpoint(model, "streamGenerateContent?alt=sse"),
                                                headers: headers, body: body, timeout: timeout)
        return HTTPTransport.stream(request, assembler: TurnAssembler(format: .serverSentEvents, decode: Self.decode,
                                                                      recording: .gemini))
    }

    /// Gemini's text models take tools. The speech and image generation models
    /// the catalogue also lists take none (their model pages say so), and are
    /// told apart by name, so this asks the network nothing. Thinking and images
    /// are left unclaimed: not every text model has them, and nothing reads them.
    func capabilities() async throws -> ModelCapabilities {
        // ponytail: a name rule for the two documented families without tools; a new one fails with Gemini's 400.
        ModelCapabilities(supportsTools: !model.contains("-tts") && !model.contains("-image"))
    }

    /// The streamed body: the turns as `contents`, the system instruction
    /// beside them, and each tool as a function declaration with its schema
    /// as `parametersJsonSchema`.
    func requestBody(messages: [TurnMessage], tools: [ToolDefinition]) throws -> [String: Any] {
        var body: [String: Any] = ["contents": try Self.contents(messages)]
        let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        if model.contains("gemini-3") {
            body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": effort.rawValue]]
        }
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": try tools.map { tool in
                ["name": tool.name, "description": tool.description,
                 "parametersJsonSchema": try JSONSerialization.jsonObject(with: tool.parameters)]
            }]]
        }
        return body
    }

    /// The turns as Gemini `contents`. A model turn that made calls sends its
    /// own record back when it has one, and otherwise its text and
    /// `functionCall` parts, the first with the signature the documentation
    /// gives for a call it did not produce. The answers to one turn's calls are
    /// one `user` turn of `functionResponse` parts, each `{"output": ...}` or
    /// `{"error": ...}`, with the call's id when the call came with one.
    static func contents(_ messages: [TurnMessage]) throws -> [[String: Any]] {
        var contents: [[String: Any]] = []
        var responses: [[String: Any]]?
        var calledIDs: Set<String> = []
        for message in messages where message.role != .system {
            if message.role == .tool {
                let call = message.call
                let key = message.isError ? "error" : "output"
                var response: [String: Any] = ["name": call?.name ?? "", "response": [key: value(of: message.text)]]
                if let id = call?.id, calledIDs.contains(id) { response["id"] = id }
                responses = (responses ?? []) + [["functionResponse": response]]
                continue
            }
            if let answered = responses {
                contents.append(["role": "user", "parts": answered])
                responses = nil
            }
            let parts = try parts(of: message)
            calledIDs = Set(parts.compactMap { ($0["functionCall"] as? [String: Any])?["id"] as? String })
            contents.append(["role": message.role == .user ? "user" : "model", "parts": parts])
        }
        if let answered = responses { contents.append(["role": "user", "parts": answered]) }
        return contents
    }

    private static func parts(of message: TurnMessage) throws -> [[String: Any]] {
        if let record = message.record, record.provider == .gemini {
            return try record.blocks.compactMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let text: [[String: Any]] = message.text.isEmpty && !message.toolCalls.isEmpty ? [] : [["text": message.text]]
        return try text + message.toolCalls.enumerated().map { index, call in
            var part: [String: Any] = ["functionCall": ["id": call.id, "name": call.name,
                                                        "args": try JSONSerialization.jsonObject(with: call.arguments)]]
            if index == 0 { part["thoughtSignature"] = "skip_thought_signature_validator" }
            return part
        }
    }

    /// A tool's text as the value it holds: the JSON it spells, or the text itself.
    private static func value(of text: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) ?? text
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
    /// `finishReason` ends the turn, but only `STOP` is a whole answer, and a
    /// round that called functions ends with it too.
    ///
    /// Every part is kept as it arrived for the turn's record, except a part
    /// that is only empty text; a part with an empty text and a signature is
    /// kept. Calls arrive whole (the Gemini API streams no partial arguments),
    /// and are handed on only once `STOP` makes the round whole, each with its
    /// own id or, without one, numbered in the order it came.
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
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for part in parts where !(part.count == 1 && part["text"] as? String == "") {
            progress.contentBlocks.append(try JSONSerialization.data(withJSONObject: part, options: .sortedKeys))
        }
        if let reason = candidate["finishReason"] as? String {
            progress.isFinished = true
            progress.recordStop(reason, wholeAnswerReasons: ["STOP"])
            if progress.isWholeAnswer { try handCalls(&progress) }
        }
        // A part marked as thought is the model's reasoning, not its answer.
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// The whole round's function calls, in the order they came.
    private static func handCalls(_ progress: inout TurnProgress) throws {
        for block in progress.contentBlocks {
            guard let part = try JSONSerialization.jsonObject(with: block) as? [String: Any],
                  let call = part["functionCall"] as? [String: Any] else { continue }
            guard let name = call["name"] as? String,
                  let arguments = (call["args"] ?? [String: Any]()) as? [String: Any] else {
                throw ProviderError.badResponse("a function call without a name, or with arguments that are no object")
            }
            progress.toolCalls.append(ToolCall(
                id: call["id"] as? String ?? "call_\(progress.toolCalls.count)",
                name: name,
                arguments: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)))
        }
    }
}

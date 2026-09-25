import Foundation

/// Claude through the Messages API, structured for one request and streamed
/// for a conversation, with tools or without. Thinking stays adaptive (the
/// default on current models); `effort` is the only knob.
///
/// A tool turn keeps its content as a `TurnRecord`, because thinking blocks
/// must return complete and unmodified beside the calls they led to, and a
/// conversation turn sets the top-level `cache_control`, so each round of a
/// tool loop reads the tools, the instructions and the history before it from
/// the cache instead of paying for them again.
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
        try converse(messages, tools: [], timeout: timeout)
    }

    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.anthropic) }
        let body = try requestBody(messages: messages, tools: tools)
        let request = try HTTPTransport.request(Self.endpoint, headers: headers, body: body, timeout: timeout)
        return HTTPTransport.stream(request, assembler: TurnAssembler(format: .serverSentEvents, decode: Self.decode,
                                                                      recording: .anthropic))
    }

    /// Every current Claude model takes tools and images, and thinks, so this
    /// asks the network nothing.
    func capabilities() async throws -> ModelCapabilities {
        ModelCapabilities(supportsTools: true, supportsThinking: true, supportsVision: true)
    }

    /// The streamed Messages body: the system instruction beside the turns,
    /// the tools as `{name, description, input_schema}`, and one automatic
    /// cache breakpoint, which the API moves to the last block of each request.
    func requestBody(messages: [TurnMessage], tools: [ToolDefinition]) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "cache_control": ["type": "ephemeral"],
            "messages": try Self.messages(messages),
        ]
        // The Messages API takes the system instruction beside the turns, not
        // as one of them.
        let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = system }
        if !model.contains("haiku") { body["output_config"] = ["effort": effort.rawValue] }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool in
                ["name": tool.name, "description": tool.description,
                 "input_schema": try JSONSerialization.jsonObject(with: tool.parameters)]
            }
        }
        return body
    }

    /// The turns in the Messages shape. An assistant message that made calls
    /// sends its own record back when it has one, and otherwise its text and
    /// `tool_use` blocks. The answers to one message's calls are one `user`
    /// message of `tool_result` blocks right after it, as the API requires. A
    /// tool message made without its call has no id, and the API refuses it.
    static func messages(_ messages: [TurnMessage]) throws -> [[String: Any]] {
        var mapped: [[String: Any]] = []
        var results: [[String: Any]]?
        for message in messages where message.role != .system {
            if message.role == .tool {
                results = (results ?? []) + [[
                    "type": "tool_result",
                    "tool_use_id": message.call?.id ?? "",
                    "content": message.text,
                    "is_error": message.isError,
                ]]
                continue
            }
            if let answered = results {
                mapped.append(["role": "user", "content": answered])
                results = nil
            }
            mapped.append(["role": message.role == .user ? "user" : "assistant",
                           "content": try content(of: message)])
        }
        if let answered = results { mapped.append(["role": "user", "content": answered]) }
        return mapped
    }

    private static func content(of message: TurnMessage) throws -> Any {
        if let record = message.record, record.provider == .anthropic {
            return try record.blocks.map { try JSONSerialization.jsonObject(with: $0) }
        }
        guard !message.toolCalls.isEmpty else { return message.text }
        let text: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
        return try text + message.toolCalls.map { call in
            ["type": "tool_use", "id": call.id, "name": call.name,
             "input": try JSONSerialization.jsonObject(with: call.arguments)]
        }
    }

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }

    /// One server-sent event of a Messages stream. The counts arrive in their
    /// own events: the input with the message's start, the output with its end.
    /// The stop reason arrives with the output count; `end_turn`,
    /// `stop_sequence` and `tool_use` are a whole round, as in `complete`, and
    /// anything else, `max_tokens` and `refusal` among them, ends it short.
    ///
    /// Each content block is kept as it streams, by index. Only when the
    /// provider ends a whole round are its blocks closed: each `tool_use`
    /// becomes a call, its input the joined `input_json_delta`s (`{}` when
    /// there were none), and the blocks go into the turn's record, thinking
    /// with its signature. A round cut short leaves no call, so an input the
    /// output limit cut in half is never run.
    static func decode(_ payload: Data, progress: inout TurnProgress) throws -> String? {
        guard let event = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        let index = event["index"] as? Int
        switch type {
        case "message_start":
            let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
            progress.inputTokens = usage?["input_tokens"] as? Int
            progress.cacheReadTokens = usage?["cache_read_input_tokens"] as? Int
            progress.cacheWriteTokens = usage?["cache_creation_input_tokens"] as? Int
        case "content_block_start":
            guard let index, let block = event["content_block"] as? [String: Any] else { return nil }
            progress.streamingBlocks[index] = StreamingBlock(start: try JSONSerialization.data(withJSONObject: block))
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            if let index, let signature = delta["signature"] as? String {
                progress.streamingBlocks[index]?.signature += signature
            }
            // A thinking delta carries "thinking" and no "text": only the
            // answer's own text is part of the turn.
            let piece = delta["text"] ?? delta["thinking"] ?? delta["partial_json"]
            if let index, let piece = piece as? String { progress.streamingBlocks[index]?.appended += piece }
            return delta["text"] as? String
        case "message_delta":
            progress.outputTokens = (event["usage"] as? [String: Any])?["output_tokens"] as? Int
            progress.recordStop((event["delta"] as? [String: Any])?["stop_reason"] as? String,
                                wholeAnswerReasons: ["end_turn", "stop_sequence", "tool_use"])
        case "message_stop":
            progress.isFinished = true
            if progress.isWholeAnswer { try closeBlocks(&progress) }
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
            throw ProviderError.badResponse(message ?? "error event")
        default:
            break
        }
        return nil
    }

    /// Closes a whole round's blocks in index order. Text, thinking, redacted
    /// thinking and tool use are kept; a block of any other type is not sent
    /// back. An empty text block is left out, since the API refuses one.
    private static func closeBlocks(_ progress: inout TurnProgress) throws {
        for (_, streamed) in progress.streamingBlocks.sorted(by: { $0.key < $1.key }) {
            guard var block = try JSONSerialization.jsonObject(with: streamed.start) as? [String: Any] else { continue }
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "") + streamed.appended
                guard !text.isEmpty else { continue }
                block["text"] = text
            case "thinking":
                block["thinking"] = (block["thinking"] as? String ?? "") + streamed.appended
                block["signature"] = (block["signature"] as? String ?? "") + streamed.signature
            case "redacted_thinking":
                break
            case "tool_use":
                let input = streamed.appended.isEmpty
                    ? block["input"] ?? [String: Any]()
                    : try JSONSerialization.jsonObject(with: Data(streamed.appended.utf8))
                guard let id = block["id"] as? String, let name = block["name"] as? String,
                      let arguments = input as? [String: Any] else {
                    throw ProviderError.badResponse("a tool call without an id, a name or an object input")
                }
                block["input"] = arguments
                progress.toolCalls.append(ToolCall(
                    id: id, name: name,
                    arguments: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)))
            default:
                continue
            }
            progress.contentBlocks.append(try JSONSerialization.data(withJSONObject: block, options: .sortedKeys))
        }
        progress.streamingBlocks = [:]
    }
}

//
//  AnthropicToolTurnTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

/// A value as sorted JSON, so two shapes compare as text.
private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

private let client = AnthropicClient(model: "claude-opus-5", effort: .high, apiKey: "sk-test")

private let status = ToolDefinition(name: "status", description: "Read the status.",
                                    parameters: Data(#"{"properties":{},"type":"object"}"#.utf8))

private let openFinder = ToolCall(id: "toolu_01A", name: "open_session", arguments: Data(#"{"app":"Finder"}"#.utf8))
private let readStatus = ToolCall(id: "toolu_01B", name: "status", arguments: Data("{}".utf8))

/// A round as the Messages API streams it: a thinking block with its
/// signature, a redacted one, the text, then two calls, the first with its
/// input split over several `input_json_delta`s and the second with none.
private let toolRound = #"""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_01","role":"assistant","content":[],"usage":{"input_tokens":2048,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The person wants "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Finder."}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIM"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"EmwKAhgBEgy3va3pzix"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Opening "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Finder 🌊"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: ping
    data: {"type":"ping"}

    event: content_block_start
    data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_01A","name":"open_session","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"app\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":" \"Fin"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"der\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":3}

    event: content_block_start
    data: {"type":"content_block_start","index":4,"content_block":{"type":"tool_use","id":"toolu_01B","name":"status","input":{}}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":4}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}

    event: message_stop
    data: {"type":"message_stop"}

    """#

/// Replays `stream` in chunks of `size` bytes, as the network cuts it.
private func replay(_ stream: String, chunked size: Int) throws
    -> (text: [String], calls: [ToolCall], assembler: TurnAssembler) {
    var assembler = TurnAssembler(format: .serverSentEvents, decode: AnthropicClient.decode, recording: .anthropic)
    var text: [String] = []
    var calls: [ToolCall] = []
    let bytes = Array(stream.utf8)
    for start in stride(from: 0, to: bytes.count, by: size) {
        text += try assembler.accept(Data(bytes[start..<min(start + size, bytes.count)]))
        calls += assembler.takeToolCalls()
    }
    return (text, calls, assembler)
}

@Suite("Anthropic's tool turn on the wire")
struct AnthropicToolTurnTests {

    @Test func theBodyCarriesToolsSystemAndOneAutomaticCacheBreakpoint() throws {
        let body = try client.requestBody(
            messages: [TurnMessage(role: .system, text: "Be brief."), TurnMessage(role: .user, text: "ciao")],
            tools: [status])
        #expect(try json(body["tools"] as Any) == #"[{"description":"Read the status.","#
            + #""input_schema":{"properties":{},"type":"object"},"name":"status"}]"#)
        #expect(try json(body["cache_control"] as Any) == #"{"type":"ephemeral"}"#)
        #expect(body["system"] as? String == "Be brief.")
        #expect(body["stream"] as? Bool == true)
        #expect(try json(body["messages"] as Any) == #"[{"content":"ciao","role":"user"}]"#)

        let textOnly = try client.requestBody(messages: [TurnMessage(role: .user, text: "ciao")], tools: [])
        #expect(textOnly["tools"] == nil)
    }

    @Test func callsGoBackAsToolUseAndTheirAnswersAsOneUserMessageAfterThem() throws {
        let mapped = try AnthropicClient.messages([
            TurnMessage(role: .system, text: "Be brief."),
            TurnMessage(role: .user, text: "Open Finder."),
            TurnMessage(role: .assistant, text: "Earlier."),
            TurnMessage(role: .user, text: "Now?"),
            TurnMessage(role: .assistant, text: "Opening.", toolCalls: [openFinder, readStatus]),
            TurnMessage(result: "refused", of: openFinder, isError: true),
            TurnMessage(result: "{}", of: readStatus, isError: false),
        ])
        #expect(mapped.count == 5)
        #expect(try json(Array(mapped.prefix(3)))
            == #"[{"content":"Open Finder.","role":"user"},{"content":"Earlier.","role":"assistant"},"#
            + #"{"content":"Now?","role":"user"}]"#)
        #expect(try json(mapped[3]) == #"{"content":[{"text":"Opening.","type":"text"},"#
            + #"{"id":"toolu_01A","input":{"app":"Finder"},"name":"open_session","type":"tool_use"},"#
            + #"{"id":"toolu_01B","input":{},"name":"status","type":"tool_use"}],"role":"assistant"}"#)
        #expect(try json(mapped[4]) == #"{"content":[{"content":"refused","is_error":true,"#
            + #""tool_use_id":"toolu_01A","type":"tool_result"},{"content":"{}","is_error":false,"#
            + #""tool_use_id":"toolu_01B","type":"tool_result"}],"role":"user"}"#)
    }

    @Test func theCacheCountsComeWithTheMessageStartApartFromTheInput() throws {
        var progress = TurnProgress()
        let start = #"{"type":"message_start","message":{"usage":{"input_tokens":3,"#
            + #""cache_read_input_tokens":2000,"cache_creation_input_tokens":40,"output_tokens":1}}}"#
        _ = try AnthropicClient.decode(Data(start.utf8), progress: &progress)
        #expect(progress.usage(wallClock: .seconds(1)) == ModelUsage(inputTokens: 3, outputTokens: nil,
                                                                     duration: .seconds(1), cacheReadTokens: 2000,
                                                                     cacheWriteTokens: 40))
    }

    @Test func anAssistantTurnWithItsRecordGoesBackAsTheRecordAndAnotherProvidersIsIgnored() throws {
        let blocks = [#"{"signature":"EqQB","thinking":"","type":"thinking"}"#,
                      #"{"id":"toolu_01B","input":{},"name":"status","type":"tool_use"}"#]
        let own = TurnRecord(provider: .anthropic, blocks: blocks.map { Data($0.utf8) })
        let echoed = try AnthropicClient.messages([
            TurnMessage(role: .assistant, text: "", toolCalls: [readStatus], record: own),
        ])
        #expect(try json(echoed[0]["content"] as Any) == "[" + blocks.joined(separator: ",") + "]")

        let foreign = TurnRecord(provider: .gemini, blocks: [Data(#"{"text":"x"}"#.utf8)])
        let rebuilt = try AnthropicClient.messages([
            TurnMessage(role: .assistant, text: "", toolCalls: [readStatus], record: foreign),
        ])
        #expect(try json(rebuilt[0]["content"] as Any) == "[" + blocks[1] + "]")
    }

    @Test("a streamed tool round yields its text and whole calls, and keeps its blocks",
          arguments: [1, 2, 3, 7, 17, 64, 4096])
    func aStreamedToolRound(size: Int) throws {
        let (text, calls, assembler) = try replay(toolRound, chunked: size)
        #expect(text == ["Opening ", "Finder 🌊"])
        #expect(calls == [
            ToolCall(id: "toolu_01A", name: "open_session", arguments: Data(#"{"app":"Finder"}"#.utf8)),
            ToolCall(id: "toolu_01B", name: "status", arguments: Data("{}".utf8)),
        ])
        #expect(try assembler.completion(wallClock: .seconds(2))
            == .completed(ModelUsage(inputTokens: 2048, outputTokens: 89, duration: .seconds(2))))

        let record = try #require(assembler.record)
        #expect(record.provider == .anthropic)
        #expect(record.blocks.map { String(decoding: $0, as: UTF8.self) } == [
            #"{"signature":"EqQBCgIYAhIM","thinking":"The person wants Finder.","type":"thinking"}"#,
            #"{"data":"EmwKAhgBEgy3va3pzix","type":"redacted_thinking"}"#,
            #"{"text":"Opening Finder 🌊","type":"text"}"#,
            #"{"id":"toolu_01A","input":{"app":"Finder"},"name":"open_session","type":"tool_use"}"#,
            #"{"id":"toolu_01B","input":{},"name":"status","type":"tool_use"}"#,
        ])
    }

    @Test func aRoundTheOutputLimitCutLeavesNoCallAndFailsShort() throws {
        let cut = #"""
            data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01A","name":"open_session","input":{}}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"app\": \"Fin"}}

            data: {"type":"content_block_stop","index":0}

            data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":16000}}

            data: {"type":"message_stop"}

            """#
        let (_, calls, assembler) = try replay(cut, chunked: 5)
        #expect(calls.isEmpty)
        #expect(assembler.record == nil)
        #expect(throws: ModelTransportError.stoppedShort(reason: "max_tokens", deltas: 0)) {
            try assembler.completion(wallClock: .seconds(2))
        }
    }

    @Test func everyCurrentModelTakesToolsAndImagesWithoutAsking() async throws {
        #expect(try await client.capabilities()
            == ModelCapabilities(supportsTools: true, supportsThinking: true, supportsVision: true))
    }

    @Test func aToolTurnWithoutTheKeyRefusesBeforeAnyRequest() {
        let keyless = ModelSelection(provider: .anthropic, model: "claude-opus-5").transport()
        let error = #expect(throws: ProviderError.self) {
            _ = try keyless.converse([TurnMessage(role: .user, text: "ciao")], tools: [status], timeout: 5)
        }
        #expect(error?.localizedDescription == "No API key for Anthropic. Add one in Settings.")
    }
}

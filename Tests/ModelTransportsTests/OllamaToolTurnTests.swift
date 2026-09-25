//
//  OllamaToolTurnTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

/// `/api/show` answers as Ollama sends them, trimmed to the fields read here.
private enum Show {
    static let qwen    = #"{"capabilities":["completion","tools","thinking"],"thinking":{"values":[false,true],"default":true}}"#
    static let gptOSS  = #"{"capabilities":["completion","tools","thinking"],"thinking":{"values":["low","medium","high"],"default":"medium"}}"#
    static let gemma   = #"{"capabilities":["completion","vision"],"details":{"family":"gemma3"}}"#
    static let unnamed = #"{"capabilities":["completion","thinking"]}"#
    static let alwaysOn = #"{"capabilities":["completion","thinking"],"thinking":{"values":[true],"default":true}}"#

    static func parsed(_ body: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }
}

/// A value as sorted JSON, so two shapes compare as text.
private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

private func client(_ model: String, _ effort: ReasoningEffort) -> OllamaClient {
    OllamaClient(model: model, effort: effort, settings: ProviderSettings())
}

private let status = ToolDefinition(name: "status", description: "Read the status.",
                                    parameters: Data(#"{"properties":{},"type":"object"}"#.utf8))

@Suite("Ollama's tool turn on the wire")
struct OllamaToolTurnTests {

    @Test func aModelWithoutThinkingOrToolsIsSentNeither() throws {
        let body = try client("gemma3", .high).requestBody(
            messages: [TurnMessage(role: .system, text: "Be brief."), TurnMessage(role: .user, text: "ciao")],
            tools: [], stream: true, show: try Show.parsed(Show.gemma))
        #expect(body["think"] == nil)
        #expect(body["tools"] == nil)
        #expect(body["model"] as? String == "gemma3")
        #expect(body["stream"] as? Bool == true)
        #expect(try json(body["messages"] as Any)
            == #"[{"content":"Be brief.","role":"system"},{"content":"ciao","role":"user"}]"#)
    }

    @Test func thinkIsSentOnlyAsTheModelAcceptsIt() throws {
        func think(_ show: String, _ effort: ReasoningEffort) throws -> Any? {
            try client("m", effort).requestBody(messages: [], tools: [], stream: true,
                                                show: try Show.parsed(show))["think"]
        }
        #expect(try think(Show.qwen, .high) as? Bool == true)
        #expect(try think(Show.qwen, .low) as? Bool == false)
        // gpt-oss names levels and takes no boolean.
        #expect(try think(Show.gptOSS, .high) as? String == "high")
        #expect(try think(Show.gptOSS, .low) as? String == "low")
        // A server that names no values still takes on and off.
        #expect(try think(Show.unnamed, .high) as? Bool == true)
        // A model that cannot turn thinking off keeps its default.
        #expect(try think(Show.alwaysOn, .low) == nil)
        #expect(try think(Show.gemma, .high) == nil)
        #expect(try think("{}", .high) == nil)
    }

    @Test func toolsAreSentAsFunctions() throws {
        let body = try client("qwen3", .low).requestBody(messages: [], tools: [status], stream: true,
                                                         show: try Show.parsed(Show.qwen))
        #expect(try json(body["tools"] as Any) == #"[{"function":{"description":"Read the status.","#
            + #""name":"status","parameters":{"properties":{},"type":"object"}},"type":"function"}]"#)
    }

    @Test func aCallAndItsAnswerTakeOllamasShape() throws {
        let call = ToolCall(id: "call_0", name: "open_session", arguments: Data(#"{"app":"Finder"}"#.utf8))
        let asked = try OllamaClient.message(TurnMessage(role: .assistant, text: "Opening.", toolCalls: [call]))
        #expect(try json(asked) == #"{"content":"Opening.","role":"assistant","tool_calls":[{"function":"#
            + #"{"arguments":{"app":"Finder"},"name":"open_session"},"type":"function"}]}"#)

        let answered = try OllamaClient.message(TurnMessage(result: #"{"status":"error"}"#, of: call, isError: true))
        #expect(try json(answered) == #"{"content":"{\"status\":\"error\"}","role":"tool","tool_name":"open_session"}"#)
    }

    /// Thinking first, then the answer's text, then the calls, then the line
    /// that ends the turn: the order a streamed tool turn arrives in.
    @Test("a streamed tool turn yields its text and whole calls, and no thinking",
          arguments: [1, 3, 17, 4096])
    func aStreamedToolTurn(size: Int) throws {
        let stream = """
            {"message":{"role":"assistant","content":"","thinking":"The person wants"},"done":false}
            {"message":{"role":"assistant","content":"","thinking":" the status."},"done":false}
            {"message":{"role":"assistant","content":"Checking."},"done":false}
            {"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"status","arguments":{}}},\
            {"id":"call_ab","function":{"index":1,"name":"open_session","arguments":{"window":"Main","app":"Finder"}}}]},"done":false}
            {"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop",\
            "prompt_eval_count":120,"eval_count":30,"eval_duration":1000000000}

            """
        var assembler = TurnAssembler(format: .newlineDelimitedJSON, decode: OllamaClient.decode)
        var text: [String] = []
        var calls: [ToolCall] = []
        let bytes = Array(stream.utf8)
        for start in stride(from: 0, to: bytes.count, by: size) {
            text += try assembler.accept(Data(bytes[start..<min(start + size, bytes.count)]))
            calls += assembler.takeToolCalls()
        }
        #expect(text == ["Checking."])
        #expect(calls == [
            ToolCall(id: "call_0", name: "status", arguments: Data("{}".utf8)),
            ToolCall(id: "call_ab", name: "open_session", arguments: Data(#"{"app":"Finder","window":"Main"}"#.utf8)),
        ])
        #expect(assembler.takeToolCalls().isEmpty)
        #expect(try assembler.completion(wallClock: .seconds(9))
            == .completed(ModelUsage(inputTokens: 120, outputTokens: 30, duration: .seconds(1))))
    }

    @Test func aCallWhoseArgumentsAreNotAnObjectIsRefused() {
        let line = #"{"message":{"tool_calls":[{"function":{"name":"status","arguments":"{}"}}]},"done":false}"# + "\n"
        var assembler = TurnAssembler(format: .newlineDelimitedJSON, decode: OllamaClient.decode)
        #expect(throws: ProviderError.self) { try assembler.accept(Data(line.utf8)) }
    }

    @Test func capabilitiesAreWhatShowLists() throws {
        #expect(OllamaClient.capabilities(show: try Show.parsed(Show.qwen))
            == ModelCapabilities(supportsTools: true, supportsThinking: true))
        #expect(OllamaClient.capabilities(show: try Show.parsed(Show.gemma)) == ModelCapabilities(supportsVision: true))
        #expect(OllamaClient.capabilities(show: [:]) == ModelCapabilities())
    }
}

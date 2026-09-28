//
//  GeminiToolTurnTests.swift
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

private let client = GeminiClient(model: "gemini-3-flash-preview", effort: .high, apiKey: "test-key")

/// The shape of the `batch` tool's schema, with the `oneOf` and `const` that
/// Gemini's OpenAPI `parameters` has no field for, sorted as `json` prints it.
private let batchSchema = #"{"additionalProperties":false,"properties":{"session":{"minLength":1,"type":"string"},"#
    + #""steps":{"items":{"oneOf":[{"additionalProperties":false,"properties":{"operation":{"const":"act"},"#
    + #""target":{"minLength":1,"type":"string"}},"required":["operation","target"],"type":"object"}]},"#
    + #""maxItems":20,"minItems":1,"type":"array"}},"required":["session","steps"],"type":"object"}"#

private let batch = ToolDefinition(name: "batch", description: "Run steps.", parameters: Data(batchSchema.utf8))

private let openFinder = ToolCall(id: "fc1", name: "open_session", arguments: Data(#"{"app":"Finder"}"#.utf8))
private let readStatus = ToolCall(id: "fc2", name: "status", arguments: Data("{}".utf8))

/// A round as `streamGenerateContent?alt=sse` sends it: a thought, the text
/// in two chunks, two calls in one chunk, the first carrying the signature,
/// then an empty text part with the finish reason.
private let toolRound = """
    data: {"candidates":[{"content":{"parts":[{"text":"The person wants Finder.","thought":true}],"role":"model"},"index":0}],\
    "usageMetadata":{"promptTokenCount":2048,"candidatesTokenCount":3}}

    data: {"candidates":[{"content":{"parts":[{"text":"Opening "}],"role":"model"},"index":0}]}

    data: {"candidates":[{"content":{"parts":[{"text":"Finder 🌊"}],"role":"model"},"index":0}]}

    data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"open_session","args":{"app":"Finder"},"id":"fc1"},\
    "thoughtSignature":"CiQBjz1rX"},{"functionCall":{"name":"status","args":{},"id":"fc2"}}],"role":"model"},"index":0}]}

    data: {"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"finishReason":"STOP","index":0}],\
    "usageMetadata":{"promptTokenCount":2048,"candidatesTokenCount":40}}

    """

/// Replays `stream` in chunks of `size` bytes, as the network cuts it.
private func replay(_ stream: String, chunked size: Int) throws
    -> (text: [String], calls: [ToolCall], assembler: TurnAssembler) {
    var assembler = TurnAssembler(format: .serverSentEvents, decode: GeminiClient.decode, recording: .gemini)
    var text: [String] = []
    var calls: [ToolCall] = []
    let bytes = Array(stream.utf8)
    for start in stride(from: 0, to: bytes.count, by: size) {
        text += try assembler.accept(Data(bytes[start..<min(start + size, bytes.count)]))
        calls += assembler.takeToolCalls()
    }
    return (text, calls, assembler)
}

@Suite("Gemini's tool turn on the wire")
struct GeminiToolTurnTests {

    @Test func toolsGoAsJSONSchemaDeclarationsWithTheirSchemaIntact() throws {
        let body = try client.requestBody(
            messages: [TurnMessage(role: .system, text: "Be brief."), TurnMessage(role: .user, text: "ciao")],
            tools: [batch])
        let tools = try #require(body["tools"] as? [[String: Any]])
        let declaration = try #require((tools.first?["functionDeclarations"] as? [[String: Any]])?.first)
        #expect(tools.count == 1)
        #expect(declaration["name"] as? String == "batch")
        #expect(declaration["description"] as? String == "Run steps.")
        #expect(declaration["parameters"] == nil)
        #expect(try json(declaration["parametersJsonSchema"] as Any) == batchSchema)
        #expect(try json(body["systemInstruction"] as Any) == #"{"parts":[{"text":"Be brief."}]}"#)
        #expect(try json(body["contents"] as Any) == #"[{"parts":[{"text":"ciao"}],"role":"user"}]"#)
        #expect(try json(body["generationConfig"] as Any) == #"{"thinkingConfig":{"thinkingLevel":"high"}}"#)

        let textOnly = try client.requestBody(messages: [TurnMessage(role: .user, text: "ciao")], tools: [])
        #expect(textOnly["tools"] == nil)
    }

    @Test func callsGoBackAsFunctionCallsAndTheirAnswersAsOneUserTurnAfterThem() throws {
        let contents = try GeminiClient.contents([
            TurnMessage(role: .system, text: "Be brief."),
            TurnMessage(role: .user, text: "Open Finder."),
            TurnMessage(role: .assistant, text: "Earlier."),
            TurnMessage(role: .user, text: "Now?"),
            TurnMessage(role: .assistant, text: "Opening.", toolCalls: [openFinder, readStatus]),
            TurnMessage(result: #"{"status":"error"}"#, of: openFinder, isError: true),
            TurnMessage(result: #"{"session":null}"#, of: readStatus, isError: false),
        ])
        #expect(contents.count == 5)
        #expect(try json(Array(contents.prefix(3)))
            == #"[{"parts":[{"text":"Open Finder."}],"role":"user"},{"parts":[{"text":"Earlier."}],"role":"model"},"#
            + #"{"parts":[{"text":"Now?"}],"role":"user"}]"#)
        // Rebuilt without a record: the first call carries the signature the documentation gives for one.
        #expect(try json(contents[3]) == #"{"parts":[{"text":"Opening."},{"functionCall":{"args":{"app":"Finder"},"#
            + #""id":"fc1","name":"open_session"},"thoughtSignature":"skip_thought_signature_validator"},"#
            + #"{"functionCall":{"args":{},"id":"fc2","name":"status"}}],"role":"model"}"#)
        #expect(try json(contents[4]) == #"{"parts":[{"functionResponse":{"id":"fc1","name":"open_session","#
            + #""response":{"error":{"status":"error"}}}},{"functionResponse":{"id":"fc2","name":"status","#
            + #""response":{"output":{"session":null}}}}],"role":"user"}"#)
    }

    @Test func aModelTurnWithItsRecordGoesBackAsTheRecordAndAnotherProvidersIsIgnored() throws {
        let parts = [#"{"text":"Opening."}"#,
                     #"{"functionCall":{"args":{},"id":"fc2","name":"status"},"thoughtSignature":"CiQB"}"#]
        let own = TurnRecord(provider: .gemini, blocks: parts.map { Data($0.utf8) })
        let echoed = try GeminiClient.contents([
            TurnMessage(role: .assistant, text: "Opening.", toolCalls: [readStatus], record: own),
            TurnMessage(result: "{}", of: readStatus, isError: false),
        ])
        #expect(try json(echoed[0]) == #"{"parts":["# + parts.joined(separator: ",") + #"],"role":"model"}"#)
        #expect(try json(echoed[1]) == #"{"parts":[{"functionResponse":{"id":"fc2","name":"status","#
            + #""response":{"output":{}}}}],"role":"user"}"#)

        let foreign = TurnRecord(provider: .anthropic, blocks: [Data(#"{"type":"text","text":"x"}"#.utf8)])
        let rebuilt = try GeminiClient.contents([
            TurnMessage(role: .assistant, text: "", toolCalls: [readStatus], record: foreign),
        ])
        #expect(try json(rebuilt[0]) == #"{"parts":[{"functionCall":{"args":{},"id":"fc2","name":"status"},"#
            + #""thoughtSignature":"skip_thought_signature_validator"}],"role":"model"}"#)
    }

    /// A model that gave its call no id gets no id back, rather than the number this module made up.
    @Test func aCallThatCameWithoutAnIdIsAnsweredWithoutOne() throws {
        let numbered = ToolCall(id: "call_0", name: "status", arguments: Data("{}".utf8))
        let record = TurnRecord(provider: .gemini, blocks: [Data(#"{"functionCall":{"args":{},"name":"status"}}"#.utf8)])
        let contents = try GeminiClient.contents([
            TurnMessage(role: .assistant, text: "", toolCalls: [numbered], record: record),
            TurnMessage(result: "{}", of: numbered, isError: false),
        ])
        #expect(try json(contents[1])
            == #"{"parts":[{"functionResponse":{"name":"status","response":{"output":{}}}}],"role":"user"}"#)
    }

    @Test("a streamed tool round yields its text and whole calls, and keeps its parts as they came",
          arguments: [1, 2, 3, 7, 17, 64, 4096])
    func aStreamedToolRound(size: Int) throws {
        let (text, calls, assembler) = try replay(toolRound, chunked: size)
        #expect(text == ["Opening ", "Finder 🌊"])
        #expect(calls == [openFinder, readStatus])
        #expect(try assembler.completion(wallClock: .seconds(2))
            == .completed(ModelUsage(inputTokens: 2048, outputTokens: 40, duration: .seconds(2))))

        let record = try #require(assembler.record)
        #expect(record.provider == .gemini)
        #expect(record.blocks.map { String(decoding: $0, as: UTF8.self) } == [
            #"{"text":"The person wants Finder.","thought":true}"#,
            #"{"text":"Opening "}"#,
            #"{"text":"Finder 🌊"}"#,
            #"{"functionCall":{"args":{"app":"Finder"},"id":"fc1","name":"open_session"},"thoughtSignature":"CiQBjz1rX"}"#,
            #"{"functionCall":{"args":{},"id":"fc2","name":"status"}}"#,
        ])
    }

    @Test func anEmptyTextPartThatCarriesTheSignatureIsKept() throws {
        let stream = """
            data: {"candidates":[{"content":{"parts":[{"text":"Ciao"}],"role":"model"}}]}

            data: {"candidates":[{"content":{"parts":[{"text":"","thoughtSignature":"EkQK"}],"role":"model"},\
            "finishReason":"STOP"}]}

            """
        let (text, calls, assembler) = try replay(stream, chunked: 9)
        #expect(text == ["Ciao"])
        #expect(calls.isEmpty)
        #expect(assembler.record?.blocks.map { String(decoding: $0, as: UTF8.self) }
            == [#"{"text":"Ciao"}"#, #"{"text":"","thoughtSignature":"EkQK"}"#])
    }

    @Test func aRoundTheOutputLimitCutLeavesNoCallAndFailsShort() throws {
        let cut = """
            data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"status","args":{},"id":"fc2"},\
            "thoughtSignature":"CiQB"}],"role":"model"}}]}

            data: {"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"finishReason":"MAX_TOKENS"}]}

            """
        let (_, calls, assembler) = try replay(cut, chunked: 5)
        #expect(calls.isEmpty)
        #expect(throws: ModelTransportError.stoppedShort(reason: "MAX_TOKENS", deltas: 0)) {
            try assembler.completion(wallClock: .seconds(2))
        }
    }

    @Test func textModelsTakeToolsAndTheSpeechAndImageModelsDoNot() async throws {
        #expect(try await client.capabilities() == ModelCapabilities(supportsTools: true))
        for model in ["gemini-2.5-flash-preview-tts", "gemini-2.5-flash-image"] {
            let generator = GeminiClient(model: model, effort: .low, apiKey: "test-key")
            #expect(try await generator.capabilities() == ModelCapabilities())
        }
    }

    @Test func aToolTurnWithoutTheKeyRefusesBeforeAnyRequest() {
        let keyless = ModelSelection(provider: .gemini, model: "gemini-3-flash-preview").transport()
        let error = #expect(throws: ProviderError.self) {
            _ = try keyless.converse([TurnMessage(role: .user, text: "ciao")], tools: [batch], timeout: 5)
        }
        #expect(error?.localizedDescription == "No API key for Gemini. Add one in Settings.")
    }
}

//
//  TurnAssemblyTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

/// Replays a provider's stream in chunks of a fixed size, which is how the
/// network delivers it: the cut falls wherever it falls, inside a UTF-8
/// sequence or halfway through an event.
private func replay(_ stream: String, chunked size: Int, format: EventStreamReader.Format,
                    decode: @escaping TurnAssembler.PayloadDecoding) throws -> (text: String, terminal: TurnEvent) {
    var assembler = TurnAssembler(format: format, decode: decode)
    var text = ""
    let bytes = Array(stream.utf8)
    for start in stride(from: 0, to: bytes.count, by: size) {
        let chunk = Data(bytes[start..<min(start + size, bytes.count)])
        text += try assembler.accept(chunk).joined()
    }
    return (text, try assembler.completion(wallClock: .seconds(2)))
}

/// A Messages stream whose answer holds a two-byte character and a four-byte
/// one, so a chunk boundary can land inside a character as well as inside an
/// event.
private let anthropicStream = """
    event: message_start
    data: {"type":"message_start","message":{"usage":{"input_tokens":11}}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Ciao, "}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"perché 🌊"}}

    event: message_delta
    data: {"type":"message_delta","usage":{"output_tokens":7}}

    event: message_stop
    data: {"type":"message_stop"}

    """

private let ollamaStream = """
    {"message":{"content":"Ciao, "},"done":false}
    {"message":{"content":"perché 🌊"},"done":false}
    {"done":true,"prompt_eval_count":11,"eval_count":7,"eval_duration":2000000000}

    """

@Suite("Assembling one streamed turn")
struct TurnAssemblyTests {

    @Test("server-sent deltas are reassembled whatever the chunk boundaries",
          arguments: [1, 2, 3, 5, 8, 17, 64, 4096])
    func serverSentDeltasSurviveEveryChunking(size: Int) throws {
        let (text, terminal) = try replay(anthropicStream, chunked: size, format: .serverSentEvents,
                                          decode: AnthropicClient.decode)
        #expect(text == "Ciao, perché 🌊")
        #expect(terminal == .completed(ModelUsage(inputTokens: 11, outputTokens: 7, duration: .seconds(2))))
    }

    @Test("newline-delimited deltas are reassembled whatever the chunk boundaries",
          arguments: [1, 2, 3, 5, 8, 17, 64, 4096])
    func newlineDelimitedDeltasSurviveEveryChunking(size: Int) throws {
        let (text, terminal) = try replay(ollamaStream, chunked: size, format: .newlineDelimitedJSON,
                                          decode: OllamaClient.decode)
        #expect(text == "Ciao, perché 🌊")
        // Ollama times its own generation, so that is the turn's duration and
        // not the wall clock the caller measured.
        #expect(terminal == .completed(ModelUsage(inputTokens: 11, outputTokens: 7, duration: .seconds(2))))
    }

    @Test func aCharacterCutInHalfIsNeverReadAsTwoCharacters() throws {
        let bytes = Array(anthropicStream.utf8)
        // One byte into the four that spell the wave, so the cut falls inside
        // the character and inside its event.
        let wave = try #require(bytes.firstRange(of: Array("🌊".utf8)))
        let cut = wave.lowerBound + 1
        var assembler = TurnAssembler(format: .serverSentEvents, decode: AnthropicClient.decode)
        var text = try assembler.accept(Data(bytes[0..<cut])).joined()
        text += try assembler.accept(Data(bytes[cut...])).joined()
        #expect(text == "Ciao, perché 🌊")
        #expect(assembler.progress.isFinished)
    }

    @Test func aStreamThatStopsBeforeTheProviderEndsTheTurnIsNotAnAnswer() throws {
        let truncated = anthropicStream.replacingOccurrences(
            of: "event: message_stop\ndata: {\"type\":\"message_stop\"}\n", with: "")
        var assembler = TurnAssembler(format: .serverSentEvents, decode: AnthropicClient.decode)
        let text = try assembler.accept(Data(truncated.utf8)).joined()
        #expect(text == "Ciao, perché 🌊")
        #expect(!assembler.progress.isFinished)
        #expect(throws: ModelTransportError.streamEndedEarly(deltas: 2)) {
            try assembler.completion(wallClock: .seconds(2))
        }
    }

    @Test func anErrorEventEndsTheTurnWithTheProvidersOwnSentence() {
        let stream = """
            event: error
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

            """
        var assembler = TurnAssembler(format: .serverSentEvents, decode: AnthropicClient.decode)
        #expect(throws: ProviderError.self) { try assembler.accept(Data(stream.utf8)) }
    }

    @Test func geminiFinishesOnTheCandidateThatCarriesAReason() throws {
        let stream = """
            data: {"candidates":[{"content":{"parts":[{"text":"Ciao"}]}}]}

            data: {"candidates":[{"content":{"parts":[{"text":" 🌊"}]},"finishReason":"STOP"}],\
            "usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":4}}

            """
        let (text, terminal) = try replay(stream, chunked: 7, format: .serverSentEvents,
                                          decode: GeminiClient.decode)
        #expect(text == "Ciao 🌊")
        #expect(terminal == .completed(ModelUsage(inputTokens: 3, outputTokens: 4, duration: .seconds(2))))
    }
}

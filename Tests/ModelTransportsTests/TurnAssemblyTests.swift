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
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

    event: message_stop
    data: {"type":"message_stop"}

    """

private let ollamaStream = """
    {"message":{"content":"Ciao, "},"done":false}
    {"message":{"content":"perché 🌊"},"done":false}
    {"done":true,"done_reason":"stop","prompt_eval_count":11,"eval_count":7,"eval_duration":2000000000}

    """

/// One stream fed whole, the deltas it yielded, and then what its end was
/// worth: the terminal element, or the error thrown after those deltas.
private func assemble(_ stream: String, format: EventStreamReader.Format,
                      decode: @escaping TurnAssembler.PayloadDecoding) throws
    -> (deltas: [String], ending: Result<TurnEvent, any Error>) {
    var assembler = TurnAssembler(format: format, decode: decode)
    let deltas = try assembler.accept(Data(stream.utf8))
    return (deltas, Result { try assembler.completion(wallClock: .seconds(2)) })
}

/// A provider stream that ends the turn with `reason` after two deltas.
struct StoppedStream: Sendable, CustomStringConvertible {
    let provider: String
    let reason  : String?
    let stream  : String
    let format  : EventStreamReader.Format
    let decode  : TurnAssembler.PayloadDecoding

    var description: String { "\(provider) \(reason ?? "without a reason")" }

    static func anthropic(_ reason: String) -> StoppedStream {
        StoppedStream(provider: "Anthropic", reason: reason, stream: """
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Ciao, "}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"perché"}}

            data: {"type":"message_delta","delta":{"stop_reason":"\(reason)"},"usage":{"output_tokens":7}}

            data: {"type":"message_stop"}

            """, format: .serverSentEvents, decode: AnthropicClient.decode)
    }

    static func ollama(_ reason: String?) -> StoppedStream {
        let field = reason.map { #""done_reason":"\#($0)","# } ?? ""
        return StoppedStream(provider: "Ollama", reason: reason, stream: """
            {"message":{"content":"Ciao, "},"done":false}
            {"message":{"content":"perché"},"done":false}
            {"done":true,\(field)"eval_count":7}

            """, format: .newlineDelimitedJSON, decode: OllamaClient.decode)
    }

    static func gemini(_ reason: String) -> StoppedStream {
        StoppedStream(provider: "Gemini", reason: reason, stream: """
            data: {"candidates":[{"content":{"parts":[{"text":"Ciao, "}]}}]}

            data: {"candidates":[{"content":{"parts":[{"text":"perché"}]},"finishReason":"\(reason)"}]}

            """, format: .serverSentEvents, decode: GeminiClient.decode)
    }
}

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

    @Test("a whole answer completes on each provider's normal stop",
          arguments: [StoppedStream.anthropic("end_turn"), .anthropic("stop_sequence"),
                      .ollama("stop"), .gemini("STOP")])
    func aNormalStopCompletes(stopped: StoppedStream) throws {
        let (deltas, ending) = try assemble(stopped.stream, format: stopped.format, decode: stopped.decode)
        #expect(deltas == ["Ciao, ", "perché"])
        guard case .completed = try ending.get() else {
            Issue.record("\(stopped) did not complete")
            return
        }
    }

    @Test("an answer the provider stopped short throws its reason after the partial deltas",
          arguments: [StoppedStream.anthropic("max_tokens"), .anthropic("refusal"),
                      .ollama("length"),
                      .gemini("MAX_TOKENS"), .gemini("SAFETY"), .gemini("RECITATION"),
                      .gemini("BLOCKLIST"), .gemini("PROHIBITED_CONTENT")])
    func aTruncatedAnswerIsNotCompleted(stopped: StoppedStream) throws {
        let (deltas, ending) = try assemble(stopped.stream, format: stopped.format, decode: stopped.decode)
        #expect(deltas == ["Ciao, ", "perché"])
        #expect(throws: ModelTransportError.stoppedShort(reason: stopped.reason, deltas: 2)) {
            try ending.get()
        }
    }

    @Test("a stop reason nobody recognises fails closed",
          arguments: [StoppedStream.anthropic("a_reason_from_next_year"), .ollama("unload"), .ollama(nil),
                      .gemini("FINISH_REASON_UNSPECIFIED")])
    func anUnknownStopReasonIsNotAWholeAnswer(stopped: StoppedStream) throws {
        let (_, ending) = try assemble(stopped.stream, format: stopped.format, decode: stopped.decode)
        #expect(throws: ModelTransportError.stoppedShort(reason: stopped.reason, deltas: 2)) {
            try ending.get()
        }
    }

    @Test func geminiThoughtPartsAreNotPartOfTheAnswer() throws {
        let stream = """
            data: {"candidates":[{"content":{"parts":[{"text":"weighing it","thought":true},{"text":"Ciao"}]}}]}

            data: {"candidates":[{"content":{"parts":[{"text":"still weighing","thought":true}]}}]}

            data: {"candidates":[{"content":{"parts":[{"text":" 🌊"}]},"finishReason":"STOP"}]}

            """
        let (deltas, ending) = try assemble(stream, format: .serverSentEvents, decode: GeminiClient.decode)
        #expect(deltas == ["Ciao", " 🌊"])
        #expect(throws: Never.self) { try ending.get() }
    }
}

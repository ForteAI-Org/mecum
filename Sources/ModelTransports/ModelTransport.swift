//
//  ModelTransport.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// ModelTransport is one way of talking to one model: a single structured
/// request, or a streamed conversational turn. It knows nothing about seats,
/// scenes or plans, and it decodes nothing: `complete` hands back the
/// provider's own text for the caller's own vocabulary to read.
///
/// Not every provider can carry a conversation. `streaming` is where a
/// transport says so, and `converse` on a transport that cannot throws
/// `ModelTransportError.streamingUnsupported` rather than returning a stream
/// that yields nothing.
public protocol ModelTransport: Sendable {

    /// How long one answer may take before the caller gives up on it. Transport
    /// policy, not the caller's: a local model is slower than an API.
    var requestTimeout: TimeInterval { get }

    /// Whether this transport streams a conversational turn, and why not when
    /// it does not.
    var streaming: StreamingSupport { get }

    /// One structured-output request. Returns the provider's raw answer text,
    /// undecoded, and what the provider says the call cost.
    func complete(prompt: String, schema: Data, timeout: TimeInterval)
        async throws -> (text: String, usage: ModelUsage)

    /// One conversational turn over the ordered messages, as text deltas
    /// followed by a single terminal `.completed`.
    ///
    /// Throws before any request when the transport declares no streaming. The
    /// stream fails with `ModelTransportError.streamEndedEarly` when the
    /// provider stops sending before it declares the turn finished, and with
    /// `ModelTransportError.stoppedShort` when the provider ends the turn for a
    /// reason other than a whole answer (the output limit, a safety filter, or
    /// a reason not recognised). Either failure arrives after the deltas already
    /// yielded, so the caller keeps the partial text and marks it incomplete: a
    /// partial answer is never finished silently. Terminating the stream
    /// cancels the request.
    func converse(_ messages: [TurnMessage], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error>

    /// One conversational turn in which the model may call `tools`: text
    /// deltas and whole `.toolCall`s in the order the model made them, then the
    /// single terminal `.completed`, with the failures `converse` has.
    ///
    /// The turn runs no tool. A caller that saw calls runs them, then starts
    /// the next turn with the assistant message that made them and one `tool`
    /// message per call. With no tools this is `converse(_:timeout:)`. A
    /// transport without a tool turn refuses tools with
    /// `ModelTransportError.toolsUnsupported` before any request.
    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error>

    /// What the model can do beyond text, as the provider confirms it now.
    /// Throws what the provider answered when it could not be asked.
    func capabilities() async throws -> ModelCapabilities
}

public extension ModelTransport {

    var requestTimeout: TimeInterval { 180 }

    /// The refusal a transport without a conversational turn owes its caller.
    /// A transport that declares `.incremental` overrides this; reaching it
    /// with that declaration is the mismatch the reason names.
    func converse(_ messages: [TurnMessage], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        throw ModelTransportError.streamingUnsupported(streaming.declaredReason)
    }

    /// A transport without a tool turn: the text turn when no tool is handed
    /// over, and the refusal otherwise.
    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        guard tools.isEmpty else { throw ModelTransportError.toolsUnsupported }
        return try converse(messages, timeout: timeout)
    }

    /// Nothing confirmed: a transport that has not asked its provider claims
    /// no capability, so a caller sends it nothing the model may refuse.
    func capabilities() async throws -> ModelCapabilities { ModelCapabilities() }
}

/// Whether a transport can carry a conversational turn. An adapter declares
/// what it cannot do rather than leaving the caller to find out from an empty
/// answer.
public enum StreamingSupport: Sendable, Hashable {

    /// Text arrives in pieces as the model generates it.
    case incremental

    /// No conversational turn exists here, for the reason given.
    case unsupported(reason: String)

    /// What a caller that asked for a turn anyway is told.
    var declaredReason: String {
        switch self {
        case .incremental:
            "the transport declares incremental streaming but implements no conversational turn"
        case .unsupported(let reason):
            reason
        }
    }
}

public extension ModelSelection {

    /// The transport this selection talks through. The only way to make one:
    /// each provider's client stays inside this module.
    func transport(settings: ProviderSettings = ProviderSettings()) -> any ModelTransport {
        switch provider {
        case .codex: CodexCLIClient(model: model, effort: effort)
        case .claudeCode: ClaudeCLIClient(model: model, effort: effort)
        case .anthropic: AnthropicClient(model: model, effort: effort, apiKey: settings.anthropicAPIKey)
        case .gemini: GeminiClient(model: model, effort: effort, apiKey: settings.geminiAPIKey)
        case .ollama: OllamaClient(model: model, effort: effort, settings: settings)
        }
    }
}

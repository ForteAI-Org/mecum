//
//  TurnEvent.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

/// One element of a streamed conversational turn: a piece of the answer, a
/// tool the model called, or the single terminal element that closes it.
///
/// `.completed` arrives only when the provider ended the turn with a reason
/// that means the answer is whole. A turn the model ended to call tools is
/// whole in that sense: its calls arrived before `.completed`, and the answer
/// continues in the next turn, after their results. Otherwise the stream fails
/// after the elements it yielded: `ModelTransportError.streamEndedEarly` when
/// the provider never said it ended, `ModelTransportError.stoppedShort` with the
/// provider's reason when it ended short. A caller that saw the terminal
/// element knows the text and the calls it assembled are the whole turn.
public enum TurnEvent: Sendable, Hashable {

    /// Text to append to the answer, exactly as the provider sent it.
    case delta(String)

    /// A tool the model called, whole, in the order it called them. Only a
    /// turn that was handed tools yields one.
    case toolCall(ToolCall)

    /// The provider declared the turn whole, and what it says it cost.
    case completed(ModelUsage)
}

/// One message handed to a conversational turn, in the order it was said. A
/// turn normally opens with a `system` instruction and alternates `user` and
/// `assistant` after it; a transport maps the roles onto its provider's own
/// shape. Within a turn with tools, an `assistant` message carries the calls
/// it made, and each call is answered by one `tool` message after it.
///
/// Named for the turn and not for the chat: an application has its own idea of
/// a chat message, with everything that application shows beside the text, and
/// this is only what a provider is sent.
public struct TurnMessage: Sendable, Hashable {

    public enum Role: String, Sendable, Hashable {
        case system, user, assistant

        /// A tool's answer to one call, made with `init(result:of:isError:)`.
        case tool
    }

    public let role: Role
    public let text: String

    /// The calls an `assistant` message made, in order. Empty on any other.
    public let toolCalls: [ToolCall]

    /// The call a `tool` message answers. Nil on any other.
    public let call: ToolCall?

    /// On a `tool` message, whether `text` reports the tool's failure rather
    /// than its result.
    public let isError: Bool

    public init(role: Role, text: String, toolCalls: [ToolCall] = []) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.call = nil
        self.isError = false
    }

    /// The answer to `call`: what the tool returned, or its failure when `isError`.
    public init(result text: String, of call: ToolCall, isError: Bool) {
        self.role = .tool
        self.text = text
        self.toolCalls = []
        self.call = call
        self.isError = isError
    }
}

//
//  TurnEvent.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

/// One element of a streamed conversational turn: a piece of the answer, or
/// the single terminal element that closes it.
///
/// A turn that ends without `.completed` never arrives: the stream fails with
/// `ModelTransportError.streamEndedEarly` instead, so a caller that saw the
/// terminal element knows the text it assembled is the whole answer.
public enum TurnEvent: Sendable, Hashable {

    /// Text to append to the answer, exactly as the provider sent it.
    case delta(String)

    /// The provider declared the turn finished, and what it says it cost.
    case completed(ModelUsage)
}

/// One message handed to a conversational turn, in the order it was said. A
/// turn normally opens with a `system` instruction and alternates `user` and
/// `assistant` after it; a transport maps the roles onto its provider's own
/// shape.
///
/// Named for the turn and not for the chat: an application has its own idea of
/// a chat message, with everything that application shows beside the text, and
/// this is only what a provider is sent.
public struct TurnMessage: Sendable, Hashable {

    public enum Role: String, Sendable, Hashable {
        case system, user, assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

//
//  Message.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData

/// MessageDelivery is how far a message has got.
///
/// There is no `read` case on purpose. Knowing that a server accepted a
/// request is not knowing that anything read it, and the UI must not claim
/// otherwise.
nonisolated enum MessageDelivery: String, Codable, Sendable, CaseIterable {

    /// Written to this store, before any routing or execution starts.
    case savedLocally

    /// Queued for a backend that has not accepted it yet.
    case pending

    /// Accepted by the backend.
    case sentToBackend

    /// An answer is streaming.
    case responding

    /// The answer finished.
    case completed

    /// The answer stopped early. Whatever arrived stays visible.
    case interrupted
}

/// Message is one turn of a conversation.
///
/// It is persisted before routing or execution begins, so a crash between the
/// two leaves the text in the store rather than in a lost view.
///
/// `sequence` is the local order inside its conversation, assigned by
/// `WorkspaceStore`. Ordering on `createdAt` would tie the transcript to the
/// clock, which moves.
@Model
nonisolated final class Message {

    #Unique<Message>([\.id])
    #Index<Message>([\.conversationID, \.sequence])

    var id: UUID

    var conversationID: UUID

    /// The worker that wrote it, or nil for the person.
    var authorWorkerID: UUID?

    var text: String

    var createdAt: Date

    /// Monotonic inside the conversation, starting at 1.
    var sequence: Int

    var delivery: MessageDelivery

    /// What this message replies to, a `MessageQuote` kept as three columns.
    /// All three are nil for a message that quotes nothing, and in a store
    /// written before replies.
    var quotedMessageID     : UUID?
    var quotedAuthorWorkerID: UUID?
    var quotedText          : String?

    init(
        id            : UUID            = UUID(),
        conversationID: UUID,
        authorWorkerID: UUID?           = nil,
        text          : String,
        createdAt     : Date            = Date(),
        sequence      : Int,
        delivery      : MessageDelivery = .savedLocally,
        quote         : MessageQuote?   = nil
    ) {
        self.id                   = id
        self.conversationID       = conversationID
        self.authorWorkerID       = authorWorkerID
        self.text                 = text
        self.createdAt            = createdAt
        self.sequence             = sequence
        self.delivery             = delivery
        self.quotedMessageID      = quote?.messageID
        self.quotedAuthorWorkerID = quote?.authorWorkerID
        self.quotedText           = quote?.text
    }
}

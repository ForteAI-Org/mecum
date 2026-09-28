//
//  Conversation.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import SwiftData

/// ConversationKind separates the three channels the product has.
///
/// Only `direct` is produced today. The Hub and the rooms are increment 3;
/// the case exists so adding them does not migrate the schema, and no code
/// here treats them as working.
nonisolated enum ConversationKind: String, Codable, Sendable, CaseIterable {
    case direct
    case hub
    case room
}

/// Conversation is one channel and everything that is remembered about
/// reading it.
///
/// Draft and reading position belong to the conversation, not to the window:
/// changing worker during a stream must not lose what was typed and must not
/// force a return to the end when the channel is reopened.
///
/// Messages are not a relationship. They are found by `conversationID` and
/// ordered by `sequence`, because a stored array is the thing that tempts a
/// caller into loading ten thousand messages to show twenty.
@Model
nonisolated final class Conversation {

    #Unique<Conversation>([\.id])

    var id: UUID

    var kind: ConversationKind

    var title: String?

    /// The workers taking part. The person is always a participant and is not
    /// listed here.
    var participantIDs: [UUID]

    /// What was typed and not sent. A failed attempt never consumes it.
    var draft: String

    /// The message the reader was anchored on, with the offset inside it.
    /// Together they restore a position rather than a scroll fraction, which
    /// a reflow would invalidate.
    var readingAnchorMessageID: UUID?
    var readingOffset         : Double

    var createdAt: Date

    /// The provider session a worker's agent resumes, and the provider that
    /// issued it. Written only together, through `ConversationChange.providerSession`
    /// and `.providerSessionCleared`, so an id recorded for one provider is never
    /// offered to another. Nil in a conversation that has not run a turn yet, and
    /// after a fresh context.
    var providerSessionProvider: ModelProvider?
    var providerSessionID      : String?

    /// How far the person has read: the highest message sequence and the
    /// highest event order in this conversation when it was last on screen at
    /// its end. The reading anchor above cannot say this, because nil there
    /// means "at the end" and the end moves. Written only by `markRead`.
    var readUpToSequence  : Int = 0
    var readUpToEventOrder: Int = 0

    /// The message the draft replies to, a `MessageQuote` kept as three
    /// columns beside the draft and written with it, so a reply in progress
    /// survives a switch of worker and a relaunch. Nil in a store written
    /// before replies.
    var draftQuoteMessageID     : UUID?
    var draftQuoteAuthorWorkerID: UUID?
    var draftQuoteText          : String?

    /// The messages sent while the worker answered, in order: JSON of
    /// `[QueuedMessage]` in a plain data column, which reads the same on every
    /// macOS version, rather than a Codable array whose encoding is SwiftData's
    /// own. Nil for an empty queue, and in a store written before the queue.
    var queuedMessages: Data?

    init(
        id                    : UUID             = UUID(),
        kind                  : ConversationKind = .direct,
        title                 : String?          = nil,
        participantIDs        : [UUID]           = [],
        draft                 : String           = "",
        readingAnchorMessageID: UUID?            = nil,
        readingOffset         : Double           = 0,
        createdAt             : Date             = Date()
    ) {
        self.id                     = id
        self.kind                   = kind
        self.title                  = title
        self.participantIDs         = participantIDs
        self.draft                  = draft
        self.readingAnchorMessageID = readingAnchorMessageID
        self.readingOffset          = readingOffset
        self.createdAt              = createdAt
    }
}

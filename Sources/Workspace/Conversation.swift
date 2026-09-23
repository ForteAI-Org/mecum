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
public enum ConversationKind: String, Codable, Sendable, CaseIterable {
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
public final class Conversation {

    #Unique<Conversation>([\.id])

    public internal(set) var id: UUID

    public internal(set) var kind: ConversationKind

    public var title: String?

    /// The workers taking part. The person is always a participant and is not
    /// listed here.
    public var participantIDs: [UUID]

    /// What was typed and not sent. A failed attempt never consumes it.
    public var draft: String

    /// The message the reader was anchored on, with the offset inside it.
    /// Together they restore a position rather than a scroll fraction, which
    /// a reflow would invalidate.
    public var readingAnchorMessageID: UUID?
    public var readingOffset         : Double

    public internal(set) var createdAt: Date

    /// The provider session a worker's agent resumes, and the provider that
    /// issued it. Written only together, through `ConversationChange.providerSession`,
    /// so an id recorded for one provider is never offered to another. Nil in
    /// a conversation that has not run a turn yet, and in every v1 store.
    public internal(set) var providerSessionProvider: ModelProvider?
    public internal(set) var providerSessionID      : String?

    public init(
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

//
//  ConversationSnapshot.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// ConversationSnapshot is a conversation as it leaves the store. It is a
/// copy: the model it came from stays inside `WorkspaceStore`.
public struct ConversationSnapshot: Sendable, Hashable, Identifiable {

    public let id                    : UUID
    public let kind                  : ConversationKind
    public let title                 : String?
    public let participantIDs        : [UUID]
    public let draft                 : String
    public let readingAnchorMessageID: UUID?
    public let readingOffset         : Double
    public let createdAt             : Date

    init(_ conversation: Conversation) {
        self.id                     = conversation.id
        self.kind                   = conversation.kind
        self.title                  = conversation.title
        self.participantIDs         = conversation.participantIDs
        self.draft                  = conversation.draft
        self.readingAnchorMessageID = conversation.readingAnchorMessageID
        self.readingOffset          = conversation.readingOffset
        self.createdAt              = conversation.createdAt
    }
}

//
//  ConversationSnapshot.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports

/// ConversationSnapshot is a conversation as it leaves the store. It is a
/// copy: the model it came from stays inside `WorkspaceStore`.
nonisolated struct ConversationSnapshot: Sendable, Hashable, Identifiable {

    let id                    : UUID
    let kind                  : ConversationKind
    let title                 : String?
    let participantIDs        : [UUID]
    let draft                 : String
    let readingAnchorMessageID: UUID?
    let readingOffset         : Double
    let createdAt             : Date

    let providerSessionProvider: ModelProvider?
    let providerSessionID      : String?

    init(_ conversation: Conversation) {
        self.id                     = conversation.id
        self.kind                   = conversation.kind
        self.title                  = conversation.title
        self.participantIDs         = conversation.participantIDs
        self.draft                  = conversation.draft
        self.readingAnchorMessageID = conversation.readingAnchorMessageID
        self.readingOffset          = conversation.readingOffset
        self.createdAt              = conversation.createdAt
        self.providerSessionProvider = conversation.providerSessionProvider
        self.providerSessionID       = conversation.providerSessionID
    }

    /// The provider session to resume when `provider` answers next, or nil
    /// when there is none or the stored one belongs to another provider.
    func resumableSession(for provider: ModelProvider) -> String? {
        providerSessionProvider == provider ? providerSessionID : nil
    }
}

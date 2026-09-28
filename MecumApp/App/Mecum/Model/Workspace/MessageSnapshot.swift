//
//  MessageSnapshot.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// MessageSnapshot is a message as it leaves the store. It is a copy: the
/// model it came from stays inside `WorkspaceStore`.
nonisolated struct MessageSnapshot: Sendable, Hashable, Identifiable {

    let id            : UUID
    let conversationID: UUID
    let authorWorkerID: UUID?
    let text          : String
    let createdAt     : Date
    let sequence      : Int
    let delivery      : MessageDelivery

    /// True when the person wrote it.
    var isFromPerson: Bool { authorWorkerID == nil }

    init(_ message: Message) {
        self.id             = message.id
        self.conversationID = message.conversationID
        self.authorWorkerID = message.authorWorkerID
        self.text           = message.text
        self.createdAt      = message.createdAt
        self.sequence       = message.sequence
        self.delivery       = message.delivery
    }
}

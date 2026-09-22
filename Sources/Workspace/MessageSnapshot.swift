//
//  MessageSnapshot.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// MessageSnapshot is a message as it leaves the store. It is a copy: the
/// model it came from stays inside `WorkspaceStore`.
public struct MessageSnapshot: Sendable, Hashable, Identifiable {

    public let id            : UUID
    public let conversationID: UUID
    public let authorWorkerID: UUID?
    public let text          : String
    public let createdAt     : Date
    public let sequence      : Int
    public let delivery      : MessageDelivery

    /// True when the person wrote it.
    public var isFromPerson: Bool { authorWorkerID == nil }

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

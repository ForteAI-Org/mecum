//
//  WorkspaceStore+Conversations.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData

extension WorkspaceStore {

    // MARK: Conversations

    @discardableResult
    func createConversation(
        id          : UUID             = UUID(),
        kind        : ConversationKind = .direct,
        title       : String?          = nil,
        participants: [UUID]           = []
    ) throws -> ConversationSnapshot {
        let conversation = Conversation(id: id, kind: kind, title: title, participantIDs: participants)
        modelContext.insert(conversation)
        try saveOrRollBack()
        return ConversationSnapshot(conversation)
    }

    func conversation(_ id: UUID) throws -> ConversationSnapshot? {
        try conversationRow(id).map(ConversationSnapshot.init)
    }

    func conversations() throws -> [ConversationSnapshot] {
        try modelContext
            .fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.createdAt)]))
            .map(ConversationSnapshot.init)
    }

    @discardableResult
    func update(conversation id: UUID, _ change: ConversationChange) throws -> ConversationSnapshot {
        guard let row = try conversationRow(id) else {
            throw WorkspaceStoreError.conversationNotFound(id)
        }

        switch change {
        case .title(let value):        row.title          = value
        case .participants(let value): row.participantIDs = value
        case .draft(let value):        row.draft          = value

        case .readingPosition(let anchor, let offset):
            row.readingAnchorMessageID = anchor
            row.readingOffset          = offset

        case .providerSession(let provider, let sessionID):
            row.providerSessionProvider = provider
            row.providerSessionID       = sessionID

        case .providerSessionCleared:
            row.providerSessionProvider = nil
            row.providerSessionID       = nil
        }

        try saveOrRollBack()
        return ConversationSnapshot(row)
    }

    // MARK: Messages

    /// Writes the message and returns it with the order it was given.
    ///
    /// This is the point the spec puts before routing: the text is in the
    /// store, saved locally, before anything is sent anywhere.
    @discardableResult
    func appendMessage(
        to conversation: UUID,
        id             : UUID  = UUID(),
        author         : UUID? = nil,
        text           : String,
        at             : Date  = Date(),
        delivery       : MessageDelivery = .savedLocally
    ) throws -> MessageSnapshot {

        guard try conversationRow(conversation) != nil else {
            throw WorkspaceStoreError.conversationNotFound(conversation)
        }

        let message = Message(
            id            : id,
            conversationID: conversation,
            authorWorkerID: author,
            text          : text,
            createdAt     : at,
            sequence      : try nextSequence(in: conversation),
            delivery      : delivery
        )
        modelContext.insert(message)
        try saveOrRollBack()
        return MessageSnapshot(message)
    }

    @discardableResult
    func update(message id: UUID, delivery: MessageDelivery) throws -> MessageSnapshot {
        guard let row = try first(Message.self, where: #Predicate { $0.id == id }) else {
            throw WorkspaceStoreError.messageNotFound(id)
        }
        row.delivery = delivery
        try saveOrRollBack()
        return MessageSnapshot(row)
    }

    /// Every message of a conversation, in order. For a long history use
    /// `messages(in:around:before:after:)` instead.
    func messages(in conversation: UUID) throws -> [MessageSnapshot] {
        try modelContext.fetch(
            FetchDescriptor<Message>(
                predicate: #Predicate { $0.conversationID == conversation },
                sortBy   : [SortDescriptor(\.sequence)]
            )
        ).map(MessageSnapshot.init)
    }

    /// A window of messages around a position, in order.
    ///
    /// Two bounded fetches, so the cost is the window rather than the history:
    /// a conversation of ten thousand messages gives back the few the reader
    /// is looking at, and a search can open a distant window without walking
    /// the pages in between.
    ///
    /// `before` messages with a lower sequence and `after` messages from
    /// `position` upwards, each clamped at zero. Read through a context made
    /// for the call (`readingContext`), so paging keeps nothing behind.
    func messages(
        in conversation: UUID,
        around position: Int,
        before         : Int,
        after          : Int
    ) throws -> [MessageSnapshot] {

        var earlier = FetchDescriptor<Message>(
            predicate: #Predicate { $0.conversationID == conversation && $0.sequence < position },
            sortBy   : [SortDescriptor(\.sequence, order: .reverse)]
        )
        earlier.fetchLimit = max(0, before)

        var later = FetchDescriptor<Message>(
            predicate: #Predicate { $0.conversationID == conversation && $0.sequence >= position },
            sortBy   : [SortDescriptor(\.sequence)]
        )
        later.fetchLimit = max(0, after)

        // A fetch limit of zero means no limit, so a side asked for none is not fetched at all.
        let context = readingContext()
        let head = before > 0 ? try context.fetch(earlier).reversed().map(MessageSnapshot.init) : []
        let tail = after  > 0 ? try context.fetch(later).map(MessageSnapshot.init) : []
        return head + tail
    }

    /// One message by its id, or nil when the store has none. The transcript
    /// reads it to find the sequence a remembered reading anchor sits at,
    /// through a context made for the call.
    func message(_ id: UUID) throws -> MessageSnapshot? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try readingContext().fetch(descriptor).first.map(MessageSnapshot.init)
    }

    func messageCount(in conversation: UUID) throws -> Int {
        try modelContext.fetchCount(
            FetchDescriptor<Message>(predicate: #Predicate { $0.conversationID == conversation })
        )
    }

    // MARK: Rows

    private func conversationRow(_ id: UUID) throws -> Conversation? {
        try first(Conversation.self, where: #Predicate { $0.id == id })
    }

    private func nextSequence(in conversation: UUID) throws -> Int {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.conversationID == conversation },
            sortBy   : [SortDescriptor(\.sequence, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.sequence ?? 0) + 1
    }
}

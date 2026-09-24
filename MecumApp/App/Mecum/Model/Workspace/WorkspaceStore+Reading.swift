//
//  WorkspaceStore+Reading.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import SwiftData

extension WorkspaceStore {

    // MARK: Read marker

    /// Moves the conversation's read marker to its end, so every message and
    /// event recorded so far counts as seen. The caller calls it only while
    /// the conversation is on screen at its end; nothing here knows the view.
    func markRead(conversation id: UUID) throws {
        guard let row = try first(Conversation.self, where: #Predicate { $0.id == id }) else {
            throw WorkspaceStoreError.conversationNotFound(id)
        }
        let end = try Self.end(of: id, in: modelContext)
        guard row.readUpToSequence != end.sequence || row.readUpToEventOrder != end.eventOrder else { return }
        row.readUpToSequence   = end.sequence
        row.readUpToEventOrder = end.eventOrder
        try saveOrRollBack()
    }

    /// What each worker's direct conversation holds past its read marker, by
    /// worker. A worker whose conversation has nothing unseen is absent.
    ///
    /// Only direct conversations with one worker are read: a room or the Hub
    /// never lights a row by itself (§4.3).
    // ponytail: reads every conversation per call; read one conversation if the team grows past tens.
    func unreadByWorker() throws -> [UUID: UnreadState] {
        var states: [UUID: UnreadState] = [:]
        for conversation in try modelContext.fetch(FetchDescriptor<Conversation>())
        where conversation.kind == .direct && conversation.participantIDs.count == 1 {
            guard let workerID = conversation.participantIDs.first else { continue }
            let state = try unread(in: conversation, from: workerID)
            if state != .none { states[workerID] = state }
        }
        return states
    }

    private func unread(in conversation: Conversation, from workerID: UUID) throws -> UnreadState {
        let id       = conversation.id
        let sequence = conversation.readUpToSequence
        let order    = conversation.readUpToEventOrder
        let author   = Optional(workerID)

        let replies = try modelContext.fetchCount(FetchDescriptor<Message>(
            predicate: #Predicate {
                $0.conversationID == id && $0.sequence > sequence && $0.authorWorkerID == author
            }
        ))
        // The type is an enum column, so the few events past the marker are filtered here.
        let hasProblem = try modelContext.fetch(FetchDescriptor<WorkspaceEvent>(
            predicate: #Predicate { $0.conversationID == id && $0.localOrder > order }
        )).contains { $0.type == .executionFailed || $0.type == .executionCancelled }

        return UnreadState(replies: replies, hasUnseenProblem: hasProblem)
    }

    /// Moves every conversation's marker to its end. The v2 to v3 migration
    /// runs it, so the history that existed before the marker reads as seen.
    static func markEverythingRead(in context: ModelContext) throws {
        for conversation in try context.fetch(FetchDescriptor<Conversation>()) {
            let end = try end(of: conversation.id, in: context)
            conversation.readUpToSequence   = end.sequence
            conversation.readUpToEventOrder = end.eventOrder
        }
        try context.save()
    }

    /// The highest message sequence and event order in the conversation, zero
    /// for none.
    private static func end(of id: UUID, in context: ModelContext) throws -> (sequence: Int, eventOrder: Int) {
        var message = FetchDescriptor<Message>(
            predicate: #Predicate { $0.conversationID == id },
            sortBy   : [SortDescriptor(\.sequence, order: .reverse)]
        )
        message.fetchLimit = 1
        var event = FetchDescriptor<WorkspaceEvent>(
            predicate: #Predicate { $0.conversationID == id },
            sortBy   : [SortDescriptor(\.localOrder, order: .reverse)]
        )
        event.fetchLimit = 1
        let sequence   = try context.fetch(message).first?.sequence ?? 0
        let eventOrder = try context.fetch(event).first?.localOrder ?? 0
        return (sequence, eventOrder)
    }
}

//
//  StreamingSource.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Transcript
@testable import Workspace

/// StreamingSource serves a store's windows with the text of some messages
/// taken from buffers that grow, the way streamed replies do between flushes,
/// so a stream is simulated and separated from any provider (§20.1).
actor StreamingSource: ConversationWindowSource {

    let store: WorkspaceStore
    private(set) var texts: [UUID: String] = [:]

    init(store: WorkspaceStore) { self.store = store }

    func append(_ delta: String, to id: UUID) { texts[id, default: ""] += delta }

    func messages(in conversation: UUID, around position: Int, before: Int, after: Int) async throws
        -> [MessageSnapshot] {
        try await store.messages(in: conversation, around: position, before: before, after: after).map(streamed)
    }

    func message(_ id: UUID) async throws -> MessageSnapshot? {
        try await store.message(id).map(streamed)
    }

    func events(inConversation conversation: UUID, from start: Date, before end: Date, limit: Int) async throws
        -> [RecordedEvent] {
        try await store.events(inConversation: conversation, from: start, before: end, limit: limit)
    }

    private func streamed(_ message: MessageSnapshot) -> MessageSnapshot {
        guard let text = texts[message.id] else { return message }
        return MessageSnapshot(Message(id: message.id, conversationID: message.conversationID,
                                       authorWorkerID: message.authorWorkerID, text: text,
                                       createdAt: message.createdAt, sequence: message.sequence,
                                       delivery: message.delivery))
    }
}

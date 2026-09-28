//
//  ConversationWindowSource.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// ConversationWindowSource is the read-only seam the transcript loads
/// windows through (§12.5). It asks for a bounded slice around a position and
/// never for a whole history.
///
/// `WorkspaceStore` conforms; a test conforms to count what is asked. Every
/// read is independent: a failure leaves the caller's window as it was.
nonisolated protocol ConversationWindowSource: Sendable {

    /// `before` messages below `position` and `after` from `position` up, in
    /// sequence order.
    func messages(in conversation: UUID, around position: Int, before: Int, after: Int) async throws
        -> [MessageSnapshot]

    func message(_ id: UUID) async throws -> MessageSnapshot?

    /// The latest `limit` of the conversation's events stamped in `start ..< end`,
    /// in local order.
    func events(inConversation conversation: UUID, from start: Date, before end: Date, limit: Int) async throws
        -> [RecordedEvent]
}

extension WorkspaceStore: ConversationWindowSource {}

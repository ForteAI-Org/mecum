//
//  WorkspaceEvent.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData

/// WorkspaceEvent is the append-only operational record.
///
/// Rows are written and read, never edited, except by the explicit
/// data-deletion operations, which are not implemented here. Projections and
/// caches are rebuilt from these rows.
///
/// `deduplicationKey` is what makes a repeated terminal result land once. It
/// is derived in `NewEvent`, never supplied by a caller.
///
/// The unique constraint below keeps one row per key, but it does not keep the
/// first arrival: SwiftData resolves a conflict by updating the existing row
/// with the incoming values, which would rewrite an append-only record. First
/// arrival wins only because `WorkspaceStore.append` finds the existing row and
/// returns it before inserting, so `append` must stay the only code that
/// inserts a `WorkspaceEvent`.
@Model
nonisolated final class WorkspaceEvent {

    #Unique<WorkspaceEvent>([\.deduplicationKey])
    #Index<WorkspaceEvent>([\.workerID, \.localOrder], [\.conversationID, \.localOrder])

    var id: UUID

    var workspaceID: UUID

    /// What the event is about: a message, an execution, a worker or a
    /// conversation. Always present, so the deduplication key is always
    /// well formed.
    var subjectID: UUID

    var conversationID: UUID?

    var workerID: UUID?

    var timestamp: Date

    /// Order inside the workspace, assigned by `WorkspaceStore` on append.
    /// It does not depend on the clock and does not move.
    var localOrder: Int

    var type: EventType

    var payloadVersion: Int

    var payload: Data?

    var correlationID: UUID?

    var deduplicationKey: String

    init(_ event: NewEvent, localOrder: Int) {
        self.id               = event.id
        self.workspaceID      = event.workspaceID
        self.subjectID        = event.subjectID
        self.conversationID   = event.conversationID
        self.workerID         = event.workerID
        self.timestamp        = event.timestamp
        self.localOrder       = localOrder
        self.type             = event.type
        self.payloadVersion   = event.payloadVersion
        self.payload          = event.payload
        self.correlationID    = event.correlationID
        self.deduplicationKey = event.deduplicationKey
    }
}

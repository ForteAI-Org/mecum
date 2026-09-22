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
/// is derived in `NewEvent`, never supplied by a caller, and the unique
/// constraint below is the enforcement: a second arrival collapses onto the
/// existing row instead of completing the same work twice.
@Model
public final class WorkspaceEvent {

    #Unique<WorkspaceEvent>([\.deduplicationKey])
    #Index<WorkspaceEvent>([\.workerID, \.localOrder], [\.conversationID, \.localOrder])

    public internal(set) var id: UUID

    public internal(set) var workspaceID: UUID

    /// What the event is about: a message, an execution, a worker or a
    /// conversation. Always present, so the deduplication key is always
    /// well formed.
    public internal(set) var subjectID: UUID

    public internal(set) var conversationID: UUID?

    public internal(set) var workerID: UUID?

    public internal(set) var timestamp: Date

    /// Order inside the workspace, assigned by `WorkspaceStore` on append.
    /// It does not depend on the clock and does not move.
    public internal(set) var localOrder: Int

    public internal(set) var type: EventType

    public internal(set) var payloadVersion: Int

    public internal(set) var payload: Data?

    public internal(set) var correlationID: UUID?

    public internal(set) var deduplicationKey: String

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

//
//  EventRecord.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// NewEvent is an event on its way into the store, before it has an order.
nonisolated struct NewEvent: Sendable, Hashable {

    var id            : UUID
    var workspaceID   : UUID

    /// The entity whose transition this is. Required: it is half of the key
    /// that keeps a repeated terminal result from being applied twice.
    var subjectID     : UUID

    var conversationID: UUID?
    var workerID      : UUID?
    var timestamp     : Date
    var type          : EventType
    var payloadVersion: Int
    var payload       : Data?
    var correlationID : UUID?

    init(
        id            : UUID      = UUID(),
        workspaceID   : UUID,
        subjectID     : UUID,
        conversationID: UUID?     = nil,
        workerID      : UUID?     = nil,
        timestamp     : Date      = Date(),
        type          : EventType,
        payloadVersion: Int       = 1,
        payload       : Data?     = nil,
        correlationID : UUID?     = nil
    ) {
        self.id             = id
        self.workspaceID    = workspaceID
        self.subjectID      = subjectID
        self.conversationID = conversationID
        self.workerID       = workerID
        self.timestamp      = timestamp
        self.type           = type
        self.payloadVersion = payloadVersion
        self.payload        = payload
        self.correlationID  = correlationID
    }

    /// What the store's unique constraint is taken on, and what
    /// `WorkspaceStore.append` looks up before it inserts. The constraint keeps
    /// one row per key and, on a conflict, updates that row with the later
    /// values; the first arrival is kept by `append`'s lookup, not by the
    /// constraint.
    ///
    /// A terminal transition is identified by its subject alone, not by its
    /// subject and its type. An execution therefore ends once however it ends:
    /// a cancellation already recorded is not joined by a completion that
    /// arrives late, and no reader is left deciding which of two terminal rows
    /// counts. The `terminal` prefix keeps these keys apart from the event ids
    /// below, which are UUIDs drawn from a different population.
    ///
    /// Every other event is identified by itself, so an event that may
    /// legitimately repeat always does. The key is computed rather than
    /// passed, so there is no caller who can forget it.
    ///
    /// The cost, stated rather than hidden: the late outcome is not recorded
    /// at all. When that fact matters it belongs in a non-terminal event
    /// saying that a provider reported after the end, never in a second
    /// terminal row.
    ///
    /// The obligation this puts on a later increment: reopening a finished
    /// task must mint a new `Execution` rather than reuse the one that ended.
    /// The new attempt's ending would otherwise carry the old attempt's key,
    /// collapse onto it and be lost without a trace.
    ///
    /// A `turnUsage` event is identified by itself too, behind `usageKeyPrefix`, so a
    /// store read can select usage rows by this string column: the type is an enum
    /// column, which a predicate cannot compare on macOS 26.
    var deduplicationKey: String {
        if type.isTerminal { return Self.terminalKey(of: subjectID) }
        return type == .turnUsage ? Self.usageKeyPrefix + id.uuidString : id.uuidString
    }

    /// What every `turnUsage` event's key starts with.
    static let usageKeyPrefix = "usage:"

    /// The key every terminal event about `subject` carries, whichever way it ends.
    static func terminalKey(of subject: UUID) -> String {
        "terminal:\(subject.uuidString)"
    }
}

/// RecordedEvent is an event as it leaves the store, with the order it was
/// given.
nonisolated struct RecordedEvent: Sendable, Hashable, Identifiable {

    let id            : UUID
    let workspaceID   : UUID
    let subjectID     : UUID
    let conversationID: UUID?
    let workerID      : UUID?
    let timestamp     : Date
    let localOrder    : Int
    let type          : EventType
    let payloadVersion: Int
    let payload       : Data?
    let correlationID : UUID?

    init(_ event: WorkspaceEvent) {
        self.id             = event.id
        self.workspaceID    = event.workspaceID
        self.subjectID      = event.subjectID
        self.conversationID = event.conversationID
        self.workerID       = event.workerID
        self.timestamp      = event.timestamp
        self.localOrder     = event.localOrder
        self.type           = event.type
        self.payloadVersion = event.payloadVersion
        self.payload        = event.payload
        self.correlationID  = event.correlationID
    }
}

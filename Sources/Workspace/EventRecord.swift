//
//  EventRecord.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// NewEvent is an event on its way into the store, before it has an order.
public struct NewEvent: Sendable, Hashable {

    public var id            : UUID
    public var workspaceID   : UUID

    /// The entity whose transition this is. Required: it is half of the key
    /// that keeps a repeated terminal result from being applied twice.
    public var subjectID     : UUID

    public var conversationID: UUID?
    public var workerID      : UUID?
    public var timestamp     : Date
    public var type          : EventType
    public var payloadVersion: Int
    public var payload       : Data?
    public var correlationID : UUID?

    public init(
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

    /// What the store's unique constraint is taken on.
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
    var deduplicationKey: String {
        type.isTerminal ? "terminal:\(subjectID.uuidString)" : id.uuidString
    }
}

/// RecordedEvent is an event as it leaves the store, with the order it was
/// given.
public struct RecordedEvent: Sendable, Hashable, Identifiable {

    public let id            : UUID
    public let workspaceID   : UUID
    public let subjectID     : UUID
    public let conversationID: UUID?
    public let workerID      : UUID?
    public let timestamp     : Date
    public let localOrder    : Int
    public let type          : EventType
    public let payloadVersion: Int
    public let payload       : Data?
    public let correlationID : UUID?

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

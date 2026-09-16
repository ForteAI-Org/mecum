//
//  Turn.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// Turn is exclusive use of one Agent Seat between two safe points. It is
/// deliberately the smallest thing that works: there is no TTL, no priority,
/// no revocation and no preemption here, because those belong to the
/// Orchestrator's SeatBroker, which builds Lease and Epoch **on top** of a Turn
/// and its generation (ADR 0006).
///
/// What the Turn does carry is the two facts a consumer cannot reconstruct:
/// which hold this is, and whether anything happened to the seat since the
/// previous one.
///
/// The rule for the consumer is one line: **generation changed, perceive again
/// before acting.** Coordinates were computed from an observation, and another
/// holder or an Issue in between means the observation may describe a window
/// that has moved.
nonisolated public struct Turn: Sendable, Equatable, Identifiable {

    /// Monotonic per seat, starting at one. It never repeats and never goes
    /// back, so a consumer can compare two holds it took minutes apart.
    public let generation: UInt64

    /// True when somebody else held the seat since this holder's previous
    /// Turn, or when an Issue passed through it. False only for a consumer
    /// picking up exactly where it left off.
    ///
    /// It is false for the very first Turn of a seat: there is no previous hold
    /// to have changed anything, and the caller is about to observe anyway.
    public let seatChangedSinceLastHold: Bool

    /// The marker every event of this hold is stamped with, and the key the
    /// Cursor Fence uses to tell the seat's own synthetic input from the
    /// person's hand. One marker per hold, which is also the span of one
    /// cursor audit.
    public let correlationID: Int64

    public var id: UInt64 { generation }

    public init(
        generation              : UInt64,
        seatChangedSinceLastHold: Bool,
        correlationID           : Int64
    ) {
        self.generation               = generation
        self.seatChangedSinceLastHold = seatChangedSinceLastHold
        self.correlationID            = correlationID
    }
}

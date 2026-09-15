//
//  FenceSignals.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// FenceSignals is one batch of everything the tap callback latched since the
/// last time somebody drained it. It is the fence's half of the contract with
/// the seat watchdog, and it exists because the two requirements on the
/// callback pull in opposite directions.
///
/// The callback must publish what it sees, and the callback must not allocate.
/// Publishing is what allocates: an `AsyncStream` yield, an actor hop, a
/// `Task {}` and an escaping closure cost roughly one, one, four and one
/// allocation respectively, measured. So the callback does not
/// publish. It writes counters and two last-value slots into preallocated
/// storage under an `os_unfair_lock`, and a consumer outside the hot path turns
/// that state into events by calling `CursorFence.drainSignals()`.
///
/// The contract the seat watchdog is built on:
///
/// - Every occurrence is **latched**, so nothing is missed between two reads.
///   This is the real difference from polling the cursor every 20 ms: the fence
///   corrects an escaping pointer within the event that carried it, so a poll
///   taken afterwards finds the pointer back inside and sees nothing at all.
/// - Draining **resets** the counters, so two consecutive drains never report
///   the same occurrence twice; the cumulative totals stay in `FenceSnapshot`.
/// - A drain is cheap and takes no lock the callback holds for long, so it is
///   safe from a heartbeat at any cadence.
/// - `isEmpty` is the whole "nothing happened" test: a watchdog that gets an
///   empty batch has proof of quiet, not absence of evidence.
nonisolated public struct FenceSignals: Sendable, Equatable {

    /// How many times the tap was disabled since the last drain. The fence
    /// re-armed itself each time, so this is a report, not an outage.
    public let tapDisabled: UInt64

    /// The reason of the most recent disable in this batch.
    public let lastDisableReason: FenceDisableReason?

    /// How many events arrived with the pointer outside the physical region
    /// since the last drain, each of them corrected by the fence.
    public let pointerOutOfRegion: UInt64

    /// The most recent point observed outside the region, before correction.
    public let lastOutOfRegionPoint: CGPoint?

    public init(
        tapDisabled         : UInt64,
        lastDisableReason   : FenceDisableReason?,
        pointerOutOfRegion  : UInt64,
        lastOutOfRegionPoint: CGPoint?
    ) {
        self.tapDisabled          = tapDisabled
        self.lastDisableReason    = lastDisableReason
        self.pointerOutOfRegion   = pointerOutOfRegion
        self.lastOutOfRegionPoint = lastOutOfRegionPoint
    }

    /// An empty batch, which is what a quiet interval answers.
    public static let quiet = FenceSignals(
        tapDisabled         : 0,
        lastDisableReason   : nil,
        pointerOutOfRegion  : 0,
        lastOutOfRegionPoint: nil
    )

    /// True when nothing was latched in this interval.
    public var isEmpty: Bool {
        tapDisabled == 0 && pointerOutOfRegion == 0
    }
}

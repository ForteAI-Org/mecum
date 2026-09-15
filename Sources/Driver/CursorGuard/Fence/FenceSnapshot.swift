//
//  FenceSnapshot.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// FenceDisableReason is why the system took the tap away. It is an enum and
/// not a sentence on purpose: the callback that records it runs under a zero
/// allocation budget, and building a `String` there would cost one allocation
/// per disable.
nonisolated public enum FenceDisableReason: String, Sendable, Equatable, CaseIterable {

    /// The tap did not answer fast enough and WindowServer dropped it.
    case timeout

    /// The person, or the system, disabled the tap (the Accessibility switch,
    /// a secure input session, a debugger stopping the process).
    case userInput
}

/// FenceSnapshot is the whole state of the Cursor Fence as fields, read under
/// the same lock the tap callback writes with. Nothing here is derived on the
/// consumer's behalf: `disableCount` greater than zero is a fact, "the seat
/// must fail closed" is a decision, and the decision is not the kit's.
///
/// The counters are cumulative for the life of the tap, so a caller that wants
/// a delta subtracts two snapshots. The
/// signals that a watchdog consumes are in `FenceSignals` instead, because
/// those reset when they are read.
nonisolated public struct FenceSnapshot: Sendable, Equatable {

    /// How many physical display bounds the region was built from.
    public let physicalDisplayCount: Int

    /// Every HID event the tap saw, disabled-tap notifications excluded.
    public let observedEventCount: UInt64

    /// Events whose location the fence rewrote, whether to the region's edge or
    /// to a synthetic anchor.
    public let clampedEventCount: UInt64

    /// Mouse downs suppressed because they started outside the region, plus the
    /// matching ups suppressed to keep the target from seeing half a press.
    public let suppressedButtonEventCount: UInt64

    /// How many times the tap was disabled since it was installed. The fence
    /// re-arms itself immediately, so this staying at zero is the only proof
    /// the person's cursor was fenced for the whole interval.
    public let disableCount: UInt64

    /// Events that arrived with the pointer already outside the physical
    /// region. Each one was corrected, which is why polling the cursor position
    /// later cannot see them.
    public let outOfRegionEventCount: UInt64

    /// Whether the tap is installed and enabled right now.
    public let isActive: Bool

    /// The most recent reason the tap was disabled, or nil if it never was.
    public let lastDisableReason: FenceDisableReason?

    /// The most recent point observed outside the region, before correction.
    public let lastOutOfRegionPoint: CGPoint?

    /// How many holders acquired the shared fence and have not released it.
    public let holderCount: Int
}

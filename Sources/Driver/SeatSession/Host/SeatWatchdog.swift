//
//  SeatWatchdog.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CursorGuard
import SeatCore

/// WatchdogViolation is one of the eight invariants of a live seat, named. The
/// Issue a violation maps to is coarse on purpose (three values for eight
/// causes), and a report needs the cause, so the cause is the type and the
/// Issue is derived from it.
nonisolated public enum WatchdogViolation: String, Sendable, Equatable, CaseIterable {

    /// The main display is not the one the seat's coordinates were taken in.
    case mainDisplayChanged

    /// A physical display moved or changed size.
    case physicalGeometryChanged

    /// The virtual display is no longer in the online display list.
    case virtualDisplayOffline

    /// The fence's tap is not installed or not enabled.
    case fenceTapInactive

    /// The tap was disabled at least once since the last check. The fence
    /// re-arms itself, so this is latched evidence and not an outage: for the
    /// interval it covers, the person's cursor was not fenced.
    case fenceTapDisabled

    /// The physical cursor was seen inside the virtual display. This check
    /// belongs to the watchdog and cannot belong to the fence: the fence knows
    /// the person's displays and deliberately knows nothing about the virtual
    /// one, so only the watchdog can combine a latched out-of-region point with
    /// the virtual display's geometry.
    case pointerEnteredVirtualDisplay

    /// The physical cursor was outside the union of the person's displays.
    case pointerLeftPhysicalRegion

    /// The global cursor position could not be read, which is not a zero.
    case pointerPositionUnavailable

    /// Whose invariant broke. All eight are host level: they are about the
    /// display and the fence, which the host owns and every seat shares.
    public var issue: SeatIssue {

        switch self {
            case .mainDisplayChanged, .physicalGeometryChanged, .virtualDisplayOffline:
                .displayChanged

            case .fenceTapInactive, .fenceTapDisabled:
                .fenceUnavailable

            case .pointerEnteredVirtualDisplay, .pointerLeftPhysicalRegion,
                 .pointerPositionUnavailable:
                .cursorInterference
        }

    }
}

/// SeatWatchdog is the eight checks as a pure function, so the engine that
/// runs them can change without the contract changing with it, and so the
/// whole set is asserted in a unit test with no Mac attached.
///
/// ## Why the engine changed and the contract did not
///
/// Run on a 20 ms timer these checks cost fifty wake-ups a second, forever, for
/// eight readings that almost never change. This runs them on events where
/// events exist (the display reconfiguration callback for the display and the
/// topology, the fence's own latch for the tap and the pointer) plus one
/// heartbeat a second that re-reads everything. About one wake-up a second
/// instead of fifty, against a budget of five.
///
/// Nothing is lost by slowing down, and one thing is gained. The fence corrects
/// a pointer that left the region **inside the event that carried it**, so a
/// 20 ms poll finds the pointer already back inside and never sees the
/// escape; the latch keeps the occurrence until somebody drains it. The slower
/// engine is the more sensitive one.
nonisolated public enum SeatWatchdog {

    /// The heartbeat's period. One second: the display and the topology have
    /// their own callback, the fence latches, and what is left for a periodic
    /// re-read is the state nothing reports (the cursor position now, the tap's
    /// enabled bit) plus the CPU sample the Monitor's quality policy needs.
    public static let heartbeat: Duration = .seconds(1)

    /// violations returns every broken invariant, empty when the seat is
    /// intact. It performs no system call: the caller supplies the readings, so
    /// the same eight checks run in a test and in the heartbeat.
    ///
    /// `signals` is the fence's latched batch. Both of its counters are used:
    /// a disable is `fenceTapDisabled`, and a latched out-of-region point is
    /// resolved against the virtual display's geometry, which is how "the
    /// pointer entered the virtual display" is told apart from "the pointer
    /// went past the edge of a physical one".
    public static func violations(
        readings: SeatReadings,
        signals : FenceSignals
    ) -> [WatchdogViolation] {

        var violations: [WatchdogViolation] = []

        if readings.mainDisplayID != readings.expectedMainDisplayID {
            violations.append(.mainDisplayChanged)
        }

        if !readings.physicalTopologyIsUnchanged {
            violations.append(.physicalGeometryChanged)
        }

        if !readings.virtualDisplayIsOnline {
            violations.append(.virtualDisplayOffline)
        }

        if !readings.fenceIsActive {
            violations.append(.fenceTapInactive)
        }

        if signals.tapDisabled > 0 {
            violations.append(.fenceTapDisabled)
        }

        // ponytail: a latched escape the fence already corrected is no longer a
        // violation. Pushing the pointer against the edge the virtual display
        // is attached to produced one HID event past the region per gesture,
        // the fence warped it back inside that same event, and this check then
        // tore the whole seat down. The escape stays visible through
        // `fenceSignals`; only a live reading outside the region fails closed.
        // Ceiling: an escape corrected within one event is invisible to the
        // heartbeat, which is the fence doing its job.

        guard let cursor = readings.cursorLocation else {
            violations.append(.pointerPositionUnavailable)
            return violations
        }

        // The two cursor checks are mutually exclusive on a live reading, and
        // the more specific one wins: a cursor inside the virtual display is by
        // construction outside the physical region, and reporting both would
        // tell the person their pointer did two different wrong things.
        if readings.virtualDisplayBounds.contains(cursor) {
            if !violations.contains(.pointerEnteredVirtualDisplay) {
                violations.append(.pointerEnteredVirtualDisplay)
            }
        } else if !readings.cursorIsInsidePhysicalRegion,
                  !violations.contains(.pointerLeftPhysicalRegion) {
            violations.append(.pointerLeftPhysicalRegion)
        }

        return violations
    }
}

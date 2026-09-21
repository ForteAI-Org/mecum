//
//  SeatIssueCause.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import SeatCore

/// SeatIssueCause is what actually broke behind a coarse `SeatIssue`.
///
/// ## Why the cause travels beside the Issue and is not carried inside it
///
/// `SeatIssue` is a `String` raw-value, `CaseIterable` enum that the state
/// machine and the recovery policy compare by value and hold in sets. An
/// associated value on one of its eighteen cases would take the raw value and
/// `CaseIterable` away from all eighteen and turn every `contains` and `==` in
/// those two pure types into a pattern match, to carry a fact that belongs to
/// one case. The Issue stays the coarse name of what happened and this says
/// which of the finer facts produced it, which is the arrangement
/// `WatchdogViolation` has had since the watchdog was written: eight causes
/// behind three Issues, published together on one event.
///
/// A cause is optional at every site. A `windowUnavailable` raised because a
/// scoped window server reading answered nothing carries none, because that one
/// call cannot tell a destroyed window from a refused Facility gate, and
/// guessing between them is the misreport this type exists to stop.
nonisolated public enum SeatIssueCause: Sendable, Equatable {

    /// One of the eight invariants of a live seat, found by the watchdog.
    case watchdog(WatchdogViolation)

    /// What is known about the target window being gone, in the kit's own terms
    /// for that question. `ClosureEvidence.provesClosure` is the half a report
    /// needs most: `absentFromReading` is the seat saying it cannot see the
    /// window and not that the window ended.
    case windowClosure(ClosureEvidence)

    /// The Issue this cause is published with, so a consumer holding a cause
    /// alone can still say which anomaly it belongs to.
    public var issue: SeatIssue {
        switch self {
            case .watchdog(let violation): violation.issue
            case .windowClosure:           .windowUnavailable
        }
    }
}

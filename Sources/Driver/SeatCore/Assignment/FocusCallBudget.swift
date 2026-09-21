//
//  FocusCallBudget.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// FocusCallBudget records the durations of the focus restore calls an episode
/// made, against the 8 ms limit that applies to every one of them.
///
/// ## What the number has to be
///
/// The value handed in is the whole of `UserFocusRestorer.restore`, entry to
/// exit, which that type already measures and reports as
/// `restoreCallNanoseconds`. Nothing here re-measures it: a budget that timed
/// its own caller would be timing a different boundary. The duration of the
/// activation primitive alone, the preparation before the call and the effect
/// observed afterwards are separate measurements and none of them may be
/// substituted for this one.
///
/// ## Why there is no average
///
/// The limit applies per call. A mean hides an overrun behind the calls that
/// were fast, so this type keeps the maximum and the number of overruns and
/// offers no mean at all. An overrun fails the performance criterion; it does
/// not trigger a second restore, and it does not on its own decide whether input
/// may be admitted, which the safety checks decide.
nonisolated package struct FocusCallBudget: Sendable, Equatable {

    /// The per call limit. It is not a hard real time guarantee of the system:
    /// it is the limit the protocol measures against and reports overruns of.
    package static let limitNanoseconds: UInt64 = 8_000_000

    package private(set) var callCount            = 0
    package private(set) var overrunCount         = 0
    package private(set) var maximumNanoseconds: UInt64 = 0

    package init() {}

    /// True when every call recorded so far stayed within the limit. A budget
    /// with no calls answers true and has proved nothing, which is why
    /// `callCount` is reported next to it.
    package var isWithinLimit: Bool { overrunCount == 0 }

    /// Records one complete restore call.
    package mutating func record(restoreCallNanoseconds duration: UInt64) {
        callCount         += 1
        maximumNanoseconds = max(maximumNanoseconds, duration)
        if duration > Self.limitNanoseconds { overrunCount += 1 }
    }
}

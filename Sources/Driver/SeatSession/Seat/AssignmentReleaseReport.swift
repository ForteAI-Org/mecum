//
//  AssignmentReleaseReport.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import CoreGraphics
import SeatCore

/// AssignmentObligationReason is why one surface of a released assignment is
/// still not where it belongs.
///
/// Each case is a different recovery, which is the only reason they are apart:
/// a window the seat could not write is moved back or its owner quit, a window
/// born on the Virtual Display has no place to be moved back to and needs the
/// consumer to name one, and a window nothing was attempted for is still
/// waiting for the operation to be asked again.
nonisolated public enum AssignmentObligationReason: String, Sendable, Equatable {

    /// The return was attempted and the readings never confirmed it. The frame
    /// the window is owed is in the obligation.
    case returnRefused

    /// A failed adoption's rollback is still owed. The window is on the Virtual
    /// Display because a move the seat made did not come back.
    case restorationOwed

    /// A window born while the application was assigned, which the seat holds
    /// and which has no place in the User Seat to go back to. This kit does not
    /// invent one: the consumer names a display.
    case noDestinationInUserSeat

    /// The deadline ran out or the operation was cancelled before this surface
    /// was reached. Nothing was written for it.
    case notAttempted
}

/// AssignmentObligation is one surface a completed release did not close, with
/// the identity that names it and the frame it is owed.
///
/// The identity is whole and not a Window ID: a number the window server hands
/// out again names a different window, and an obligation a person is asked to
/// finish by hand has to survive that. The frame is nil only when there is none
/// to give, which is `noDestinationInUserSeat`.
///
/// There is no sentence here. The kit answers in fields and the consumer writes
/// the prose, which is the same rule every other report in this package keeps.
nonisolated public struct AssignmentObligation: Sendable, Equatable {

    public let identity : WindowIdentity
    public let owedFrame: CGRect?
    public let reason   : AssignmentObligationReason

    public var windowNumber: Int { identity.windowNumber }

    public init(identity: WindowIdentity, owedFrame: CGRect?, reason: AssignmentObligationReason) {
        self.identity  = identity
        self.owedFrame = owedFrame
        self.reason    = reason
    }
}

/// AssignmentReleaseOutcome is what one call to `releaseAssignment` did with
/// the assignment itself, told apart from what it did with the windows.
nonisolated public enum AssignmentReleaseOutcome: Sendable, Equatable {

    /// The assignment ended. The seat may be entrusted with another instance,
    /// and whatever is in `obligations` is a cleanup the person is owed.
    case released

    /// Nothing was assigned. It is the answer to the second call of a double
    /// teardown and not a failure: there was nothing left to close.
    case nothingAssigned

    /// Refused before any effect, because the seat is in the middle of
    /// something the assignment is the authority for. Nothing moved.
    case refused(AssignmentUse)

    /// The deadline ran out or the task was cancelled with windows still held.
    /// **The assignment is deliberately left standing**: it is what entrusts
    /// the return of what is still out there, and ending it here would leave
    /// obligations nothing can discharge. Asking again resumes.
    case cancelled
}

/// AssignmentReleaseReport is the whole answer of releasing one assignment: the
/// assignment's own end, what happened to each window, which surfaces were
/// found already settled, and what is still owed.
///
/// `windows` and `obligations` are the two halves the audit found disagreeing:
/// a warning about one auxiliary surface, then a final report that listed no
/// window at all. Every surface this operation touched is in `windows`, every
/// surface it could not close is in `obligations`, and the seat keeps the
/// per-window answers so the host's own teardown report carries them too.
nonisolated public struct AssignmentReleaseReport: Sendable, Equatable {

    public let outcome: AssignmentReleaseOutcome

    /// What the seat answered for every window it let go, by Window ID.
    public let windows: [Int: WindowReleaseOutcome]

    /// Surfaces the reconciliation settled before anything was written: a
    /// Window ID the window server proved closed, or a window already standing
    /// at the frame it is owed. Nothing was moved for these.
    public let reconciled: [Int]

    /// What is still out of place, in Window ID order.
    public let obligations: [AssignmentObligation]

    /// True when the assignment ended and nothing is left owed.
    public var isComplete: Bool {
        obligations.isEmpty && (outcome == .released || outcome == .nothingAssigned)
    }

    public init(
        outcome    : AssignmentReleaseOutcome,
        windows    : [Int: WindowReleaseOutcome] = [:],
        reconciled : [Int] = [],
        obligations: [AssignmentObligation] = []
    ) {
        self.outcome     = outcome
        self.windows     = windows
        self.reconciled  = reconciled
        self.obligations = obligations
    }
}

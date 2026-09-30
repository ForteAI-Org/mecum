//
//  BriefActivationOutcome.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

/// BriefActivationOutcome is what `AgentSeat.bringTargetBrieflyInFront` did:
/// how long the target was in front and whether the caller's condition held,
/// or why nothing was brought in front at all.
///
/// The durations run from the request that brought the target in front, on the
/// seat's monotonic clock, and are whole milliseconds. Neither `ready` nor
/// `notReady` says anything about the condition after the front went back: the
/// caller reads its own state again.
nonisolated public enum BriefActivationOutcome: Sendable, Equatable {

    /// The condition held this long after the request, and the front went
    /// back to the person's side.
    case ready(afterMilliseconds: Int)

    /// The condition did not hold within the bound, and the front went back to
    /// the person's side all the same.
    case notReady(afterMilliseconds: Int)

    /// The seat refused, and says why. Nothing was brought in front, except for
    /// `frontRequestRefused`, whose front is handed back if it moved anyway.
    case refused(Refusal)

    /// The target still held the front after the handback and its 250 ms
    /// verification. The ordinary focus recovery has the episode now: the seat
    /// is waiting, as it is for any activation of its target.
    case handbackNotVerified

    /// Why the seat brought nothing in front.
    public enum Refusal: String, Sendable, Equatable {

        /// The host was not configured to restore the person's focus, or the
        /// facility is not qualified on this build: nothing could give it back.
        case noFocusRecovery

        /// The seat is not ready: acting, waiting, recovering, failed, tearing
        /// down, moving a window, or its focus recovery is paused.
        case seatNotReady

        /// A dialog of the driven application is open in the seat. It is what
        /// disables the menus, and a moment in front would not enable them.
        case dialogOpen

        /// No window of the person's own is in front to give the front back to.
        case noUserWindow

        /// The seat holds no target window, or its identity could not be
        /// resolved for the request.
        case targetNotPrepared

        /// The request for the front was refused or threw.
        case frontRequestRefused
    }
}

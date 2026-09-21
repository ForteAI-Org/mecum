//
//  InputPauseReason.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// InputPauseReason is why a Command was not admitted, named at the point that
/// refused it.
///
/// Every stop used to arrive as one `inputPaused` with nothing attached, so a
/// consumer reading a failed run could not tell a gate held closed by a window
/// transfer from a hold that had ended, an inactive fence, or a preparation that
/// belonged to another action. They are different situations with different
/// answers, and a log that shows only the pause hides which one happened.
///
/// It is a name, not a promise: a reason describes the reading that refused,
/// which a later reading may no longer agree with. Nothing here reopens the
/// gate, and nothing here is a retry policy.
nonisolated public enum InputPauseReason: String, Sendable, Equatable, CaseIterable, Comparable {

    // MARK: The gate's own causes, each with one owner

    /// The person's focus is being restored and the focused user window is not
    /// verified yet.
    case focusRecovery

    /// The seat is staging a window or moving its operating target.
    case windowTransfer

    /// Focus recovery stopped. Terminal: nothing resolves it.
    case focusRecoveryStopped

    /// The person stopped the seat. Terminal: nothing resolves it.
    case deliberateStop

    // MARK: The recovery's pre-action preparation

    /// The hold that admitted input is over, so there is no action to prepare.
    case holdEnded

    /// Recovery has an activation it has not verified, so input stays paused
    /// until the focused user window agrees twice or the person takes over.
    case activationUnverified

    /// The cursor fence is not active. Input is never admitted without it.
    case fenceInactive

    /// The seat's focus recovery was replaced after this preparation was
    /// installed, so the preparation belongs to a recovery that is gone.
    case recoveryReplaced

    /// The seat has no action in flight to prepare for.
    case noActionInFlight

    /// The seat left the acting state while the Command was on its way to the
    /// driver. An issue reported during an action does that, which is what an
    /// adopted application activating itself looks like from here.
    case seatNotActing

    /// The hold that this preparation was made under is no longer the current
    /// one.
    case turnChanged

    /// The seat or its recovery is gone while a preparation was outstanding.
    case recoveryUnavailable

    /// The restore request named a window that the prepared destination is not
    /// about. The private writer never activates an unprepared window.
    case destinationNotPrepared

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

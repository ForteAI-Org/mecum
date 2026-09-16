//
//  SeatStateMachine.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import SeatCore

/// SeatStateMachine is the transition table of spec section 5, as a pure
/// function of the state and the Issues detected in it.
///
/// It is pure so that the table is the thing under test rather than the
/// timing around it: every row of the table is one assertion here, and neither
/// a display nor a tap is needed to make it.
///
/// The precedence is the load-bearing part, not the individual rows. A batch of
/// Issues arrives together (the guard returns all of them at once), and a
/// recoverable Issue hidden in a batch with a critical one must never soften
/// it. So the answer is decided by the worst Issue in the batch, and "worst" is
/// spelled out here once instead of at each call site.
nonisolated public enum SeatStateMachine {

    /// next returns the state the seat moves to, or the state it was already in
    /// when the batch changes nothing.
    ///
    /// A host-level Issue is answered here too: it fails the seat, because the
    /// display or the fence it was acting through stopped being trustworthy.
    /// The host's own transition is `SeatHost`'s, and the host is the one that
    /// tears the display down.
    public static func next(from state: SeatState, issues: [SeatIssue]) -> SeatState {

        // Terminal is terminal: a failed seat is never reused, so no Issue and
        // no absence of Issues brings it back.
        guard state != .failed else { return .failed }

        guard !issues.isEmpty else { return state }

        // A critical Issue of either level fails the seat. `monitorUnavailable`
        // is the one host Issue that is not critical: the person loses the
        // preview, the seat keeps acting.
        if issues.contains(where: { $0.isCritical && $0.level != .window }) { return .failed }

        // The person's choice, and the only state with no deadline.
        if issues.contains(.targetActivated) { return .waiting }

        if issues.contains(where: { [.windowUnavailable, .geometryChanged, .snapshotChanged].contains($0) }) {
            return .recovering
        }

        // A Preparation the target refused to give back, and a preview that
        // went away: both leave a seat that still acts.
        if issues.contains(.preparationNotRestored) || issues.contains(.monitorUnavailable) {
            return .degraded
        }

        // `windowStashed` is a window-level Issue: the stage failed, that
        // window gets no input, the seat is untouched.
        return state
    }

    /// resolved returns the state a seat goes back to once a recoverable
    /// episode is over, which is `ready` unless something non essential is
    /// still missing.
    ///
    /// A seat that came from `degraded` stays `degraded`: the recovery answered
    /// the window Issue, not the missing preview.
    public static func resolved(from state: SeatState, wasDegraded: Bool) -> SeatState {

        guard state != .failed else { return .failed }

        return wasDegraded ? .degraded : .ready
    }
}

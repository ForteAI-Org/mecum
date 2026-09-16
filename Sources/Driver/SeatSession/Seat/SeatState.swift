//
//  SeatState.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// SeatState is where one Agent Seat is in its life. The eight values are not
/// a status label: `send` refuses on all but two of them, and which two is the
/// whole reason the enum exists.
///
/// `waiting` preserves the work while the target is active. With explicit
/// user-focus recovery enabled, it also covers the interval until the previous
/// user window is verified again. A failed or ambiguous recovery keeps waiting
/// for the user; it does not time out into process termination.
nonisolated public enum SeatState: String, Sendable, Equatable, CaseIterable {

    /// No window has been adopted yet, or the host is not ready.
    case unavailable

    /// A window is being adopted: moved, confirmed, staged.
    case starting

    /// Ready to act. The only state `acquire` hands out a Turn from.
    case ready

    /// A Command is in flight.
    case acting

    /// The target application is active in the User Seat. No input is sent and
    /// nothing is relocated until focus recovery is verified or the user
    /// returns control; there is no terminal timeout.
    case waiting

    /// A recoverable Issue is being answered inside the recovery budget.
    case recovering

    /// Operating with something non essential missing.
    case degraded

    /// Terminal. A failed seat is never reused: the host may adopt again into
    /// a new one.
    case failed

    /// True when a Command may be posted. `degraded` acts: what degraded it is
    /// by definition not what the Command needs.
    public var acceptsCommands: Bool {
        self == .ready || self == .degraded
    }

    /// True when nothing more will happen without the host adopting again.
    public var isTerminal: Bool { self == .failed }
}

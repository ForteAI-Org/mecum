//
//  SeatActivity.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import SeatInput
import SeatSession

/// What the seat is doing, as the kit itself answers it.
///
/// It is derived from the kit's own `SeatState`, its focus recovery outcome
/// and the causes holding its input gate closed, and from nothing else. The
/// lab used to show a badge built from whether its permissions were granted,
/// which said "Seat ready" for the whole of a 107 second wait with the seat
/// internally waiting and the gate shut. A local flag can only be optimistic,
/// so there is none here: every value below is a reading.
public enum SeatActivity: String, Sendable, Hashable {

    /// No seat exists, or it holds nothing.
    case noSeat

    /// The gate is open and a Command would be admitted.
    case ready

    /// A recoverable episode is being answered, focus included. It ends by
    /// itself, one way or the other.
    case recovering

    /// Nothing more happens until the person acts: the focus is theirs, or a
    /// closure transition spent its budget and will not ask again.
    case waitingForUser

    /// Input is held back for a cause that is not the person's focus: the
    /// person's own stop, a window transfer, a suspension of the seat.
    case suspended

    /// Terminal. The seat is never reused and the host must adopt again.
    case failed

    /// What the badge says.
    public var title: String {
        switch self {
        case .noSeat:         "No seat"
        case .ready:          "Seat ready"
        case .recovering:     "Seat recovering"
        case .waitingForUser: "Seat waiting for you"
        case .suspended:      "Seat suspended"
        case .failed:         "Seat failed"
        }
    }

    /// The SF Symbol beside it.
    public var symbol: String {
        switch self {
        case .noSeat:         "circle.dashed"
        case .ready:          "checkmark.seal"
        case .recovering:     "arrow.triangle.2.circlepath"
        case .waitingForUser: "hand.raised"
        case .suspended:      "pause.circle"
        case .failed:         "exclamationmark.triangle"
        }
    }

    /// True while no Command would be admitted, which is what a person reading
    /// the badge actually wants to know.
    public var holdsInput: Bool { self != .ready }

    /// The reading, from the three things the kit publishes and nothing else.
    ///
    /// The order is the precedence and it is the load-bearing part. A terminal
    /// stop outranks every other reading, because the person pressed it and
    /// the seat state does not move when they do: `stopAdmittingCommands`
    /// closes the gate and leaves the seat `ready`, which is exactly the
    /// reading a status badge must never repeat. Then the person's focus, then
    /// a recovery in flight, then any other cause holding the gate, and only a
    /// seat with nothing against it reads ready.
    public static func reading(state: SeatState?,
                               recovery: UserFocusRecoveryReport.Outcome?,
                               pauses: [InputPauseReason]) -> SeatActivity {
        guard let state else { return .noSeat }
        if state == .failed { return .failed }
        if pauses.contains(.deliberateStop) || pauses.contains(.focusRecoveryStopped) { return .suspended }
        if recovery == .waitingForUser || recovery == .unrecoverable || state == .waiting {
            return .waitingForUser
        }
        if recovery == .restoring || pauses.contains(.focusRecovery)
            || pauses.contains(.activationUnverified) {
            return .recovering
        }
        if !pauses.isEmpty { return .suspended }
        // Exhaustive on purpose: a state the kit adds has to be read here
        // rather than fall into a default that flatters it.
        switch state {
        case .unavailable:                 return .noSeat
        case .starting, .recovering:       return .recovering
        // Acting is a Command going out, which is the opposite of held.
        case .ready, .degraded, .acting:   return .ready
        case .waiting, .failed:            return .waitingForUser
        }
    }
}

//
//  SeatHostState.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// SeatHostState is where the owner of the Virtual Display and of the shared
/// Cursor Fence is in its life.
///
/// The difference from `SeatState` is what a state means for the person's own
/// machine: a failed seat leaves the person untouched, while a failed host
/// means the virtual display or the fence stopped being trustworthy, so every
/// seat on it fails and the display comes down. `degraded` is the one state
/// that is operational with something missing, and today the only thing that
/// can be missing is the Monitor: the person cannot see the seat, the seat
/// still works.
nonisolated public enum SeatHostState: String, Sendable, Equatable, CaseIterable {

    /// Nothing is on: no virtual display, no fence.
    case off

    /// `start` is running. Display created, `NSScreen` awaited, topology
    /// attached and verified, fence installed. The step is atomic: if any part
    /// of it fails, whatever came up is taken back down.
    case starting

    /// Display and fence are up and verified, and the watchdog is running.
    case ready

    /// Operational without the Monitor (`monitorUnavailable`). Seats keep
    /// acting; only the human's view of the display is missing.
    case degraded

    /// A host invariant broke. Every seat is failed, the windows are released
    /// best effort and the display is torn down.
    case failed

    /// True when `makeSeat` may hand out a seat.
    public var canAdopt: Bool {
        self == .ready || self == .degraded
    }
}

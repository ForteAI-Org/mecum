//
//  PhysicalDisplay.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// PhysicalDisplay is one of the person's screens as the kit recorded it: its
/// id and the bounds it had when the Seat Host started. It is a reading taken
/// once, not a live view, because the whole point of a baseline is to be
/// comparable to what the machine looks like later.
nonisolated public struct PhysicalDisplay: Sendable, Equatable {

    public let displayID: CGDirectDisplayID

    /// The Quartz bounds at baseline time, origin at the top left of the main
    /// display.
    public let bounds: CGRect

    public init(displayID: CGDirectDisplayID, bounds: CGRect) {
        self.displayID = displayID
        self.bounds    = bounds
    }

    /// The display's bounds right now, for comparison against `bounds`.
    public var currentBounds: CGRect { CGDisplayBounds(displayID) }
}

/// TopologyRestoration is what the kit did, or deliberately did not do, when
/// asked to put the person's displays back where it found them.
///
/// `changedByUser` is not a failure and it is not an error case: unplugging a
/// screen while the seat runs is the person using their own Mac, and the kit
/// writing the old origins back over that would be the kit deciding for them.
/// It is reported so a Seat Host can say so, and then nothing is touched.
nonisolated public enum TopologyRestoration: Sendable, Equatable {

    /// The origins were written back.
    case restored

    /// Nothing to do: main display and every physical origin already match the
    /// baseline.
    case notNeeded

    /// The display set or the display sizes no longer match the baseline. The
    /// kit touched nothing.
    case topologyChangedByUser
}

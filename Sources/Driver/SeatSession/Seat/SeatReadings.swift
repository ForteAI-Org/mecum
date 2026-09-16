//
//  SeatReadings.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// SeatReadings is one instant of the running system as the session layer sees
/// it: the eight values the watchdog checks, taken together.
///
/// Taken together matters. Reading the cursor, then the display bounds, then
/// the tap's state leaves three instants in one verdict, and a verdict on three
/// instants can accuse the person of something the seat did between them. So
/// the readings are gathered once, into this value, and every check runs
/// against the same instant.
nonisolated public struct SeatReadings: Sendable, Equatable {

    /// The display CoreGraphics calls main right now.
    public let mainDisplayID: CGDirectDisplayID

    /// The display it was when the seat started.
    public let expectedMainDisplayID: CGDirectDisplayID

    /// Whether every physical display kept its bounds.
    public let physicalTopologyIsUnchanged: Bool

    /// Whether the virtual display is in the online display list.
    public let virtualDisplayIsOnline: Bool

    /// The virtual display's Quartz bounds, empty when there is none.
    public let virtualDisplayBounds: CGRect

    /// Whether the fence's tap is installed and enabled.
    public let fenceIsActive: Bool

    /// The global cursor position, nil when unreadable.
    public let cursorLocation: CGPoint?

    /// Whether the cursor is inside the union of the person's displays.
    public let cursorIsInsidePhysicalRegion: Bool

    public init(
        mainDisplayID              : CGDirectDisplayID,
        expectedMainDisplayID      : CGDirectDisplayID,
        physicalTopologyIsUnchanged: Bool,
        virtualDisplayIsOnline     : Bool,
        virtualDisplayBounds       : CGRect,
        fenceIsActive              : Bool,
        cursorLocation             : CGPoint?,
        cursorIsInsidePhysicalRegion: Bool
    ) {
        self.mainDisplayID                = mainDisplayID
        self.expectedMainDisplayID        = expectedMainDisplayID
        self.physicalTopologyIsUnchanged  = physicalTopologyIsUnchanged
        self.virtualDisplayIsOnline       = virtualDisplayIsOnline
        self.virtualDisplayBounds         = virtualDisplayBounds
        self.fenceIsActive                = fenceIsActive
        self.cursorLocation               = cursorLocation
        self.cursorIsInsidePhysicalRegion = cursorIsInsidePhysicalRegion
    }

    /// Gathers one instant from a sensing witness. The cursor is read once and
    /// the region test uses that same point, which is the whole point of the
    /// type.
    public init(sensing: some SeatSensing, expectedMainDisplayID: CGDirectDisplayID) {

        let cursor = sensing.cursorLocation

        self.init(
            mainDisplayID              : sensing.mainDisplayID,
            expectedMainDisplayID      : expectedMainDisplayID,
            physicalTopologyIsUnchanged: sensing.physicalTopologyIsUnchanged,
            virtualDisplayIsOnline     : sensing.virtualDisplayIsOnline,
            virtualDisplayBounds       : sensing.virtualDisplayBounds,
            fenceIsActive              : sensing.fenceIsActive,
            cursorLocation             : cursor,
            cursorIsInsidePhysicalRegion: cursor.map(sensing.fenceContainsPhysicalPoint) ?? false
        )
    }
}

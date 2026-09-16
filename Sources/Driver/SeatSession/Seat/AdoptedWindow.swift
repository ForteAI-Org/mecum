//
//  AdoptedWindow.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore

/// ReleaseMode is where a window goes when the seat lets it go.
nonisolated public enum ReleaseMode: String, Sendable, Equatable {

    /// Back to the frame it had in the User Seat. The default: a window the kit
    /// borrowed is a window the kit gives back.
    case returnToUserSeat

    /// Left on the virtual display, stashed. For a caller that will adopt it
    /// again in a moment and does not want the person's screen to flicker.
    case leaveOnVirtualDisplay
}

/// AdoptedWindow is a target window a seat moved onto the Virtual Display, with
/// the original frame recorded so that releasing it returns it to the User
/// Seat.
///
/// It is a handle and not a snapshot of the window's current state. Whether it
/// is on stage right now is the seat's answer (`AgentSeat.isStaged`), because a
/// value handed to the caller would go stale the moment Stage Manager stashed
/// it: Stage Manager keeps exactly one window on stage and stashes whatever was
/// there before, which happens without anybody asking.
nonisolated public struct AdoptedWindow: Sendable, Equatable, Identifiable {

    /// The window as it sits on the virtual display, after the move was
    /// confirmed twice.
    public let reference: WindowReference

    /// The frame the window had in the User Seat, which `release` returns it
    /// to.
    public let originalFrame: CGRect

    /// The window's title when it was adopted, used only by the structural
    /// recovery path: a window whose Window ID is momentarily not associable
    /// with an accessibility element is matched by exactly one title and size,
    /// or not at all. Empty means that path is off and a recovery refuses
    /// rather than guessing.
    public let title: String

    public var id: Int { reference.windowNumber }

    public init(reference: WindowReference, originalFrame: CGRect, title: String = "") {
        self.reference     = reference
        self.originalFrame = originalFrame
        self.title         = title
    }
}

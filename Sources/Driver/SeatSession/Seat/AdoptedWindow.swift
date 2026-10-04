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
    /// to. It is the application's own accessibility body, because that is
    /// what the seat writes back through `AXPosition`. A window taken in place
    /// inside the Virtual Display records its confirmed settled body: no
    /// physical frame was borrowed and no birth-time resize is owed.
    public let originalFrame: CGRect

    /// The **window server's** rectangle for the same window in the same
    /// place, read once before the move, so that a return can be verified
    /// against a window server reading without comparing two sources.
    ///
    /// The two disagree by a systematic per-application amount: MarkEdit's
    /// body is 885 by 448 pt where the server publishes 888 by 448, measured
    /// identically on two launches. Verifying the return against
    /// `originalFrame` left that window on the virtual display; verifying it
    /// against this one removes the offset from the comparison instead of
    /// absorbing it in a tolerance.
    ///
    /// `nil` when the reading was missing, named a different window, or did
    /// not describe the frame the window is owed, which is what a Stage
    /// Manager thumbnail and a window shrunk to fit the display both do. The
    /// return then falls back to `originalFrame` at
    /// `VirtualWindowPlacementCheck.crossSourceTolerance`.
    public let originalServerFrame: CGRect?

    /// The window's title when it was adopted, used only by the structural
    /// recovery path: a window whose Window ID is momentarily not associable
    /// with an accessibility element is matched by exactly one title and size,
    /// or not at all. Empty means that path is off and a recovery refuses
    /// rather than guessing.
    public let title: String

    /// The display the window was taken from, so the return leg names a display
    /// instead of inferring one from a rectangle. `nil` when it could not be
    /// read; the return then falls back to the project's existing policy and
    /// never picks an arbitrary display.
    public let originalDisplayID: CGDirectDisplayID?

    /// Whether the window was in **native macOS fullscreen** when the seat took
    /// it. Kept separately from the frame, and kept at all, because a release
    /// that is refused otherwise leaves nothing in the model that knows this
    /// window was ever in fullscreen.
    ///
    /// It is not the same fact as the frame: a maximised window and a native
    /// fullscreen one had the identical rectangle on every machine measured,
    /// (0, 33, 1512, 949) for both, so the rectangle cannot carry this.
    public let wasFullScreen: Bool

    /// True for a surface drawn inside another window of the same application,
    /// which the seat owns and owes nothing back: an AppKit sheet is the case
    /// that exists.
    ///
    /// A sheet born while the agent works is born on the Virtual Display like
    /// any other new window, and the adoption would otherwise record the frame
    /// it was born at as what it is owed on its return. It is owed nothing: it
    /// has no place of its own in the User Seat, it cannot be placed anywhere
    /// its host is not, and it disappears with the host. So the seat holds a
    /// record and a platform for it, and the handback is not refused over it.
    ///
    /// It is decided once, from the accessibility evidence that was current
    /// when the surface was taken in, and never recomputed: once the host has
    /// closed, nothing can say any more what this surface used to be attached
    /// to, and that is exactly when the handback asks.
    public let owesNoReturn: Bool

    public var id: Int { reference.windowNumber }

    public init(
        reference          : WindowReference,
        originalFrame      : CGRect,
        title              : String = "",
        originalDisplayID  : CGDirectDisplayID? = nil,
        wasFullScreen      : Bool = false,
        originalServerFrame: CGRect? = nil,
        owesNoReturn       : Bool = false
    ) {
        self.reference           = reference
        self.originalFrame       = originalFrame
        self.title               = title
        self.originalDisplayID   = originalDisplayID
        self.wasFullScreen       = wasFullScreen
        self.originalServerFrame = originalServerFrame
        self.owesNoReturn        = owesNoReturn
    }

    /// The same adopted window read again at a new reference.
    ///
    /// Geometry is the only thing a restage or a target switch establishes
    /// anew. Identity, provenance and what the seat owes for the window were
    /// decided by the evidence the adoption had, and rebuilding the record
    /// from parts is how `owesNoReturn` went back to its default and a sheet
    /// acquired a return obligation nobody could honour. Every place that
    /// writes a fresh reading into a held record goes through here, so a
    /// property added to this record is carried by all of them.
    public func withReference(_ reference: WindowReference) -> AdoptedWindow {
        AdoptedWindow(
            reference          : reference,
            originalFrame      : originalFrame,
            title              : title,
            originalDisplayID  : originalDisplayID,
            wasFullScreen      : wasFullScreen,
            originalServerFrame: originalServerFrame,
            owesNoReturn       : owesNoReturn
        )
    }
}

//
//  ClosureGeometryEffect.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import CoreGraphics
import SeatCore

/// ClosureGeometryEffect is what a dialog closure did to the geometry of the
/// window underneath it, measured from the frame attested before the Command
/// against the frame read after it.
///
/// ## Why the measurement exists
///
/// A live Escape closed a remote panel, the closure of its window was verified
/// independently, and the seat then failed with `geometryChanged` turning into
/// `ambiguousEffect`: the host had moved and nothing had measured by how much,
/// so an effect the seat could describe was indistinguishable from one nobody
/// could. The cause of that movement is still to be qualified live; what is
/// decided here is only whether the movement is a property a recovery can act
/// on, and that is decided from two frames rather than from the Command.
///
/// ## What it never authorizes
///
/// Nothing here posts, repeats or cancels anything. A dialog whose closure was
/// verified is closed, and re-driving it to recover a frame would be sending a
/// second Cancel for a dialog that is not there: the classification's only
/// consequence is which recovery the seat is allowed to run.
nonisolated public enum ClosureGeometryEffect: Sendable, Equatable {

    /// The window is where it was. The closure changed nothing here.
    case unchanged

    /// The window moved and kept its size, under the same identity, and is
    /// still on the display the seat placed it on. It is a translation, which
    /// is exactly what a relocation can undo.
    case hostMoved(from: CGRect, to: CGRect)

    /// Anything else: unreadable, another lifetime of the Window ID, a size
    /// that changed as well, or a frame that left the display. Nothing measured
    /// says what the input did, so it stays an unknown effect.
    case unknownEffect

    /// Classifies one window across a closure. `before` is the reference the
    /// closure transition attested **before** the Command; `after` is a reading
    /// taken now, nil when the window server has none.
    ///
    /// The identity is compared and not just the Window ID: a number the system
    /// handed out again names another window, and a movement measured between
    /// two different windows is not a movement.
    public static func classify(
        before       : WindowReference,
        after        : WindowReference?,
        within bounds: CGRect
    ) -> ClosureGeometryEffect {

        guard let after, after.hasSameIdentity(as: before) else { return .unknownEffect }

        if VirtualWindowPlacementCheck.framesMatch(before.frame, after.frame) { return .unchanged }

        guard VirtualWindowPlacementCheck.framesMatch(
                  CGRect(origin: .zero, size: before.frame.size),
                  CGRect(origin: .zero, size: after.frame.size)
              ),
              bounds.contains(after.frame)
        else { return .unknownEffect }

        return .hostMoved(from: before.frame, to: after.frame)
    }
}

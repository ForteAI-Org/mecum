//
//  SurfacePlacement.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// SurfacePlacement is the geometry the assignment nucleus needs and nothing
/// else: is this frame inside that display, and where on a display does a window
/// of this size go so a person can see all of it.
///
/// It is one namespace rather than two private copies because containment and
/// restitution ask the same two questions at the two ends of an assignment, and
/// two copies of a rounding rule are two chances to disagree. It reads nothing
/// and never chooses a display: the caller supplies the bounds it wants.
nonisolated package enum SurfacePlacement {

    /// True when the frame is entirely inside the bounds and both rectangles are
    /// readings worth comparing. A null, empty or infinite rectangle is not
    /// contained in anything, which is the honest answer for a window that is
    /// gone or in transition.
    package static func isContained(_ frame: CGRect, within bounds: CGRect) -> Bool {
        rectangleIsUsable(frame) && rectangleIsUsable(bounds) && bounds.contains(frame)
    }

    /// The frame a window of this size takes on this display: its own size when
    /// it fits, clamped to the display when it does not, centred and rounded
    /// down to whole points so two runs of the same case land identically.
    ///
    /// Answers nil rather than a fallback when either rectangle is unusable. A
    /// destination invented from an unusable reading is exactly the arbitrary
    /// placement this kit must not perform.
    package static func visibleFrame(forSizeOf frame: CGRect, on bounds: CGRect) -> CGRect? {

        guard rectangleIsUsable(frame), rectangleIsUsable(bounds) else { return nil }

        let width  = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        return CGRect(
            x     : (bounds.minX + (bounds.width  - width)  / 2).rounded(.down),
            y     : (bounds.minY + (bounds.height - height) / 2).rounded(.down),
            width : width,
            height: height
        )
    }
}

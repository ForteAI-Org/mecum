//
//  InputCommand+DragPath.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore

nonisolated extension InputCommand {

    /// The number of intermediate points a drag carries. Eight is not a taste:
    /// a three point drag and an eight step one were both measured, and on
    /// Chromium only the second arrived, prepared or not.
    public static let dragStepCount = 8

    /// A straight drag from one point to another, sampled the way the
    /// measurement says a drag has to be sampled.
    ///
    /// Both frames of reference are interpolated, and not one derived from the
    /// other: the map between a screen point and a window point is a
    /// translation, so interpolating both gives the same answer as converting.
    /// The driver may later update every screen point for a newly observed pure
    /// window translation before constructing the gesture.
    public static func drag(
        from start: InputLocation,
        to end    : InputLocation,
        steps     : Int = dragStepCount,
        modifiers : Modifiers = []
    ) -> InputCommand {

        let count = max(steps, 1)
        var path: [InputLocation] = []
        path.reserveCapacity(count + 2)
        path.append(start)

        for step in 1...count {
            let progress = CGFloat(step) / CGFloat(count)
            let screenPoint = interpolate(start.screenPoint, end.screenPoint, progress)
            let windowPoint = interpolate(
                    start.windowPointFromTop,
                    end.windowPointFromTop,
                    progress
                )
            if let geometry = start.observedGeometry,
               geometry == end.observedGeometry {
                path.append(InputLocation(
                    screenPoint       : screenPoint,
                    windowPointFromTop: windowPoint,
                    observedIn        : geometry
                ))
            } else {
                path.append(InputLocation(
                    screenPoint       : screenPoint,
                    windowPointFromTop: windowPoint
                ))
            }
        }
        // The last step already lands on `end`, and the end point is appended
        // again on purpose: the measured path holds the target still for one
        // `leftMouseDragged` before the release, which is what a hand does and
        // what the Chromium drag was measured against.
        path.append(end)
        return .drag(points: path, modifiers: modifiers)
    }

    private static func interpolate(
        _ start : CGPoint,
        _ end   : CGPoint,
        _ amount: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * amount,
            y: start.y + (end.y - start.y) * amount
        )
    }
}

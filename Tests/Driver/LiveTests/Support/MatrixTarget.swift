//
//  MatrixTarget.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import WindowPlacement

/// MatrixTarget is one black box the matrix drives: how to find it, where to
/// aim, and how to read what happened. The two implementations are the two
/// families the kit ships a platform for, and neither of them is cooperating
/// with the driver in any way the kit could rely on: the fixture publishes a
/// file, the browser page writes its own window title.
@MainActor
protocol MatrixTarget: AnyObject {

    /// The name the outcome table prints.
    var name: String { get }

    /// The platform whose policy this family was measured with.
    var platform: any InputPlatform { get }

    /// The identity the driver acts on, re-read from the window server.
    var window: WindowReference { get }

    /// What "full size" means for this window, so `stage` can tell a staged
    /// window from a Stage Manager thumbnail.
    var expectedSize: CGSize { get }

    /// Whether the target believes **itself** active. The Preparation grants
    /// exactly that, inside the target's process, and it is reported next to
    /// the User Seat invariants rather than counted as a violation of them.
    var isInternallyActive: Bool { get }

    /// Everything the target knows about the last event it received, for the
    /// line under a failed row.
    var diagnostics: String { get }

    func refresh()

    /// The counters the matrix compares before and after each action.
    func state() -> [String: Double]

    func clickPoint() -> CGPoint?
    func scrollPoint() -> CGPoint?
    func dragEndpoints() -> (start: CGPoint, end: CGPoint)?
}

extension MatrixTarget {

    /// The two frames of reference the driver needs, from one Quartz point and
    /// the same window geometry under which the target published that point.
    ///
    /// The window frame comes from `WindowServerProbe` and never from the
    /// application: a window the person's Stage Manager has stashed reports its
    /// full size to itself and a thumbnail to the window server, and the event
    /// is routed with the window server's numbers.
    func location(of point: CGPoint) throws -> InputLocation {
        let pointFrame = window.frame
        guard let reference = WindowServerProbe.geometry(of: window.windowNumber),
              reference.frame == pointFrame,
              let geometry  = WindowGeometryProbe.observation(of: reference),
              geometry.window.frame == pointFrame,
              let location  = InputLocation(screenPoint: point, observedIn: geometry)
        else {
            throw LiveFailure.windowGeometryUnavailable(window.windowNumber)
        }
        return location
    }

    /// The identity to hand the seat, with the size the window really has.
    ///
    /// `window` is the window server's reading, and for a window Stage Manager
    /// has stashed that reading is a thumbnail: 154 by 152 points for the
    /// browser in this run. A seat that centred a thumbnail and then staged it
    /// put a 1200 by 828 window half off the bottom of the display, and the
    /// placement confirmation refused it, which is the right refusal about the
    /// wrong number. The size a target reports about itself is the one to place
    /// by.
    var fullSizeReference: WindowReference {
        window.replacingFrame(CGRect(origin: window.frame.origin, size: expectedSize))
    }

    /// Whether the window server shows this window at full size inside the
    /// given display, which is what `adopt` has to guarantee before anything is
    /// posted, before it may post anything.
    func isStaged(within bounds: CGRect) -> Bool {
        guard let frame = WindowServerProbe.geometry(of: window.windowNumber)?.frame else {
            return false
        }
        return bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
            && abs(frame.width - expectedSize.width) <= 2
    }
}

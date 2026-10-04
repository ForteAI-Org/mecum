//
//  SeatDrivingFailure.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import SeatCore

/// SeatDrivingFailure names why the seat could not see or act for the engine.
public enum SeatDrivingFailure: Error, Equatable {

    /// The seat holds no adopted window to look at or act on.
    case notAdopted
    /// The window server does not attest this window number for this process.
    case windowNotAttested(number: Int, processID: Int32)
    /// The first observation must belong to the window entrusted to this target, including its
    /// process lifetime and owning connection. No scene or input is supplied for another window.
    case initialWindowChanged(expected: WindowIdentity, observed: WindowIdentity?)
    /// A still came back without pixels or without valid geometry.
    case frameUnusable
    /// The gesture's point is outside the adopted window, where the seat refuses to post: a pop-up
    /// is a window of its own and is chosen with the keyboard, never clicked.
    case pointOutsideTarget(CGPoint)
    /// The seat has no delivery for this gesture.
    case gestureUnsupported(String)
    /// No pixel-to-screen geometry has been observed yet; a scene must be perceived before acting.
    case noGeometry
    /// The target borrows a host and a seat another owner started, and bringing them up is that
    /// owner's: nothing was started.
    case borrowedLifecycle
}

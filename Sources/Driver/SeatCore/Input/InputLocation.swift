//
//  InputLocation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// InputLocation carries the same point twice, in the two frames of reference
/// the delivery needs: the Quartz screen point the event is built with, and the
/// point inside the window measured from its top left, which is what the target
/// process reads once the event is routed to its window. The driver checks the
/// pair against its bound observation and may update only the screen half for
/// a proven pure translation before it constructs the Command.
public struct InputLocation: Sendable, Equatable {

    /// The point in global Quartz coordinates, origin at the top left of the
    /// main display.
    public let screenPoint: CGPoint

    /// The point inside the target window, origin at the window's top left.
    public let windowPointFromTop: CGPoint

    /// The geometry reading that produced both points. `nil` is retained for
    /// source compatibility, but the Background Driver refuses an unbound
    /// mouse Command before constructing its first event.
    public let observedGeometry: WindowGeometryObservation?

    public init(screenPoint: CGPoint, windowPointFromTop: CGPoint) {
        self.screenPoint        = screenPoint
        self.windowPointFromTop = windowPointFromTop
        self.observedGeometry   = nil
    }

    /// Creates a point from coordinates measured under one explicit geometry
    /// observation. The observation is captured here, never added later by the
    /// driver to make an older coordinate appear current.
    public init(
        screenPoint       : CGPoint,
        windowPointFromTop: CGPoint,
        observedIn geometry: WindowGeometryObservation
    ) {
        self.screenPoint        = screenPoint
        self.windowPointFromTop = windowPointFromTop
        self.observedGeometry   = geometry
    }

    /// Creates a location from one screen point under an attested observation,
    /// deriving the window-local half so callers cannot accidentally mix two
    /// frames of reference. The window bounds are half open, like pixel bounds.
    public init?(
        screenPoint       : CGPoint,
        observedIn geometry: WindowGeometryObservation
    ) {
        guard screenPoint.x.isFinite,
              screenPoint.y.isFinite,
              screenPoint.x >= geometry.window.frame.minX,
              screenPoint.y >= geometry.window.frame.minY,
              screenPoint.x < geometry.window.frame.maxX,
              screenPoint.y < geometry.window.frame.maxY
        else { return nil }

        self.init(
            screenPoint       : screenPoint,
            windowPointFromTop: CGPoint(
                x: screenPoint.x - geometry.window.frame.minX,
                y: screenPoint.y - geometry.window.frame.minY
            ),
            observedIn        : geometry
        )
    }

    /// Creates a point selected in one captured image. The frame attachments,
    /// not the configured filter size, define the pixel-to-screen transform.
    public init?(
        pixelPoint       : CGPoint,
        observedIn frame : FrameGeometryObservation
    ) {
        guard let screenPoint = frame.screenPoint(fromPixelPoint: pixelPoint),
              let geometry    = frame.windowObservation
        else { return nil }

        self.init(
            screenPoint       : screenPoint,
            windowPointFromTop: CGPoint(
                x: screenPoint.x - geometry.window.frame.minX,
                y: screenPoint.y - geometry.window.frame.minY
            ),
            observedIn        : geometry
        )
    }

    /// Both points must be finite before an event is built: a NaN coordinate
    /// posted to another process is a click at an unknown place.
    public var isFinite: Bool {
        screenPoint.x.isFinite && screenPoint.y.isFinite
            && windowPointFromTop.x.isFinite && windowPointFromTop.y.isFinite
    }
}

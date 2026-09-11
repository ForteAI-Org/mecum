//
//  WindowGeometryObservation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics

/// WindowGeometryObservation binds one attested window lifetime to geometry
/// and display scale read together. An `InputLocation` keeps this value from
/// the observation that produced its coordinates, so the driver never blesses
/// an old point by attaching geometry read only when the Command is sent.
nonisolated public struct WindowGeometryObservation: Sendable, Equatable {

    /// The attested target and its observed frame in Quartz screen points.
    public let window: WindowReference

    /// Pixels per Quartz point on the one display that wholly contained the
    /// window when it was observed.
    public let scaleFactor: CGFloat

    /// The local observation revision. It does not claim an OS generation.
    public let version: GeometryObservationVersion

    /// Creates a coordinate authority only from finite geometry, a positive
    /// scale and a complete WindowServer identity. A raw PID and Window ID can
    /// remain a compatibility `WindowReference`, but cannot authorize input.
    public init?(
        window     : WindowReference,
        scaleFactor: CGFloat,
        version    : GeometryObservationVersion
    ) {
        guard window.identity != nil,
              window.frame.hasFinitePositiveArea,
              scaleFactor.isFinite,
              scaleFactor > 0
        else { return nil }

        self.window      = window
        self.scaleFactor = scaleFactor
        self.version     = version
    }
}

nonisolated package extension CGRect {

    var hasFinitePositiveArea: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
            && maxX.isFinite && maxY.isFinite
            && width > 0 && height > 0
    }
}

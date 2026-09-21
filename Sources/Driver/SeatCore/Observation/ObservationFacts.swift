//
//  ObservationFacts.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// ObservationInvalidation is why the current observation stopped being the
/// current one. It is reported instead of "no observation" so that a consumer
/// knows whether to observe again, to wait, or to stop.
nonisolated public enum ObservationInvalidation: String, Sendable, Equatable {

    /// Nothing has been observed yet in this lifecycle.
    case never

    /// A complete Command was posted, so the next one needs a new observation.
    case commandCompleted

    /// The Selected Target moved to another surface, or was given up.
    case targetChanged

    /// The observed window's geometry is no longer the observed one.
    case geometryChanged

    /// A menu interaction began, so the parent's observation is not current.
    case menuOpened

    /// A menu interaction ended; the target's own observation has to be taken
    /// again, and the parent's previous Still does not come back.
    case menuClosed

    /// The assignment ended or another instance was handed over.
    case lifecycleChanged

    /// A cause of the gate appeared while the observation was outstanding.
    case suspensionRaised

    /// The consumer asked for it.
    case requestedByConsumer
}

/// ObservationFacts is the world as it is at the moment of admission: what the
/// seat holds right now, gathered into one value so the whole verdict is about
/// one instant rather than about four readings taken while the checks ran.
nonisolated package struct ObservationFacts: Sendable, Equatable {

    package let instance           : ProcessIdentity
    package let surface            : WindowIdentity
    package let selectionGeneration: UInt64
    package let geometryVersion    : GeometryObservationVersion
    package let observedFrame      : CGRect
    package let role               : ObservedSurfaceRole

    /// The configured finite positive limit the content age is compared with.
    package let frameAgeLimitNanoseconds: UInt64

    package init(
        instance                : ProcessIdentity,
        surface                 : WindowIdentity,
        selectionGeneration     : UInt64,
        geometryVersion         : GeometryObservationVersion,
        observedFrame           : CGRect,
        role                    : ObservedSurfaceRole,
        frameAgeLimitNanoseconds: UInt64
    ) {
        self.instance                 = instance
        self.surface                  = surface
        self.selectionGeneration      = selectionGeneration
        self.geometryVersion          = geometryVersion
        self.observedFrame            = observedFrame
        self.role                     = role
        self.frameAgeLimitNanoseconds = frameAgeLimitNanoseconds
    }
}

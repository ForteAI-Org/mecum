//
//  SeatObservationDelivery.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import SeatCapture
import SeatCore

/// SeatObservationDelivery is one Frame and the Observation Reference that binds
/// it, handed over together.
///
/// They travel as one value because they are only meaningful together: pixels
/// without the reference are an image nobody can act on, and the reference
/// without the pixels is a token with nothing behind it. The consumer keeps the
/// whole value across its own asynchronous work, including a Vision call, and
/// hands the reference back with the Command it decided.
///
/// ## One Frame per receiver
///
/// The capture pool is three surfaces for the whole pipeline, so a receiver
/// holds at most one of these at a time. The kit does not keep a second one to
/// build a state view from, and there is no path that returns a previous Frame:
/// a new delivery replaces the previous one, and the previous reference stops
/// being the current one at that moment.
///
/// ## The age is a fact about the content
///
/// `contentAge` is the age of the pixels when the delivery was made, measured
/// through a qualified oracle or explicitly unknown. It is not the time the
/// callback arrived. An unknown age is delivered rather than hidden, and it
/// refuses the Command at admission exactly as an expired one does, so a
/// consumer can see the gap before it plans anything.
nonisolated public struct SeatObservationDelivery: Sendable {

    public let frame    : SeatFrame
    public let reference: SeatObservationReference

    /// The exact capture target that produced `frame`, when a family crop was
    /// necessary. Consumers that start a live preview reuse it verbatim rather
    /// than trying to reconstruct a nested modal chain from the leaf role.
    public let captureTarget: SeatCaptureTarget?

    /// The window geometry the sample's own attachments support, which is what a
    /// coordinate in the Frame is converted through.
    public let geometry: WindowGeometryObservation

    /// The age of the content at delivery, or why it is unknown.
    public var contentAge: FrameContentAge { reference.contentAge }

    /// Whether this is the dedicated surface of a transient menu, and of which
    /// parent.
    public var role: ObservedSurfaceRole { reference.role }

    package init(
        frame    : SeatFrame,
        reference: SeatObservationReference,
        geometry : WindowGeometryObservation,
        captureTarget: SeatCaptureTarget? = nil
    ) {
        self.frame     = frame
        self.reference = reference
        self.geometry  = geometry
        self.captureTarget = captureTarget
    }
}

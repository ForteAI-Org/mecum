//
//  SeatCaptureObservationSource.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Dispatch
import SeatCapture
import SeatCore

/// SeatCaptureObservationSource is the shipped adapter over `SeatCaptureStream`.
///
/// ## What it supports, and what it refuses
///
/// A Still of an attested window lifetime goes through `SeatCaptureStream.still`
/// with the observational barrier in the request identity, so a post Command
/// request is never coalesced into a pre barrier job.
///
/// The dedicated surface of a transient menu is **not** supported. The filter
/// this module builds is `SCContentFilter(desktopIndependentWindow:)`, and
/// nothing here establishes that aiming it at a menu window yields that menu's
/// pixels with geometry a coordinate transform can use. Until that ability is
/// qualified, the menu path refuses before any effect with the capability named,
/// and no parent Frame is offered in its place.
///
/// The content clock is not supported either. That is not this adapter's choice
/// to make differently: `FrameSampleQualifier` asks its clock oracle, and the
/// shipped oracle answers unknown, so an observation taken here is delivered
/// with an unknown age and every Command carrying it is refused at admission.
/// Composing this source therefore activates the capture path and does not
/// activate input.
nonisolated public struct SeatCaptureObservationSource: ObservedSurfaceSourcing {

    private let displayGeneration: UInt64

    public init(displayGeneration: UInt64) {
        self.displayGeneration = displayGeneration
    }

    public func supports(_ capability: ObservationCapability) -> Bool {
        switch capability {
            case .windowStill     : true
            case .menuSurfaceStill: false
            case .contentClock    : false
        }
    }

    public func captureWindowStill(
        of identity        : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {

        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineNanoseconds > now else {
            throw ObservationUnavailable.captureDeadlineExpired(attemptsSpent: 0)
        }
        return try await SeatCaptureStream.still(
            of                : .attestedWindow(identity),
            displayGeneration : displayGeneration,
            observationBarrier: observationBarrier,
            timeout           : .nanoseconds(Int64(min(deadlineNanoseconds - now, UInt64(Int64.max))))
        )
    }

    public func captureMenuStill(
        of identity        : WindowIdentity,
        parent             : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {
        throw ObservationUnavailable.capabilityUnqualified(.menuSurfaceStill)
    }
}

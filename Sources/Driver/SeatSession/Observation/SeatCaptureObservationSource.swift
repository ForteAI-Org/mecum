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
/// The content clock is supported by the host's separate
/// `MachAbsoluteContentClock`, which converts the documented WindowServer Mach
/// timestamp. A one-shot result that omits it is replaced by the first complete
/// stream frame carrying it. `FrameSampleQualifier` still refuses a malformed
/// timestamp, and a stream that cannot provide one expires inside the same
/// capture deadline.
nonisolated public struct SeatCaptureObservationSource: ObservedSurfaceSourcing {

    private let displayGeneration: UInt64

    public init(displayGeneration: UInt64) {
        self.displayGeneration = displayGeneration
    }

    public func supports(_ capability: ObservationCapability) -> Bool {
        switch capability {
            case .windowStill     : true
            case .menuSurfaceStill: false
            case .contentClock    : true
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
        let target = SeatCaptureTarget.attestedWindow(identity)
        let still = try await SeatCaptureStream.still(
            of                : target,
            displayGeneration : displayGeneration,
            observationBarrier: observationBarrier,
            timeout           : .nanoseconds(Int64(min(deadlineNanoseconds - now, UInt64(Int64.max))))
        )
        guard still.displayTime == nil else { return still }

        let afterStill = DispatchTime.now().uptimeNanoseconds
        guard deadlineNanoseconds > afterStill else {
            throw ObservationUnavailable.captureDeadlineExpired(attemptsSpent: 1)
        }
        return try await SeatCaptureStream.timestampedStill(
            of               : target,
            pixelSize        : still.pixelSize,
            displayGeneration: displayGeneration,
            timeout          : .nanoseconds(Int64(min(
                deadlineNanoseconds - afterStill,
                UInt64(Int64.max)
            )))
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

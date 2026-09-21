//
//  ObservedSurfaceSourcing.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import SeatCapture
import SeatCore

/// ObservedSurfaceSourcing supplies the pixels one observation needs, and says
/// which of the abilities it needs this system has evidence for.
///
/// ## Why the qualification is part of the role
///
/// Capturing the dedicated surface of a transient menu and capturing an ordinary
/// window are two native abilities, and each carries its own evidence: the
/// second was qualified first, the first on the AppKit family later. A conformer
/// answers `supports` for what it has evidence of, and the seat refuses the
/// corresponding operation before any effect, with the capability named. A
/// conformer that answered true for everything would not make the ability
/// exist, it would make the refusal disappear.
///
/// ## Ownership and cancellation
///
/// One call performs one native attempt and owns whatever it started. A thrown
/// `CancellationError` or a deadline reached by the caller does not prove the
/// native call ended: the conformer keeps accounting for the resource, and the
/// caller must not treat a timeout as a freed slot. Conformers are borrowed by
/// the seat for the seat's lifetime and never take ownership of the seat.
nonisolated public protocol ObservedSurfaceSourcing: Sendable {

    /// True only where the ability has evidence on this system.
    func supports(_ capability: ObservationCapability) -> Bool

    /// Captures one Still of an attested window lifetime.
    ///
    /// `observationBarrier` travels into the capture request's identity so that
    /// a request made after a Command cannot be coalesced into a job started
    /// before it. `deadlineNanoseconds` is the caller's absolute monotonic
    /// deadline, shared by every attempt of the request.
    func captureWindowStill(
        of identity        : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame

    /// Captures one attested hosted-sheet family as a display crop. The host
    /// remains the frame source; `screenRect` is the exact union the pixels
    /// occupy, so a child extending past the host cannot be mapped as padding.
    func captureWindowRegionStill(
        host                : WindowIdentity,
        children            : [WindowIdentity],
        displayID           : CGDirectDisplayID,
        screenRect          : CGRect,
        sourceWindowFrame   : CGRect,
        observationBarrier  : UInt64,
        deadlineNanoseconds : UInt64
    ) async throws -> SeatFrame

    /// Captures one Still of the dedicated surface of a transient menu,
    /// attributed to `parent`. The parent's own Frame is never substituted for
    /// it, and there is no fallback to the desktop.
    func captureMenuStill(
        of identity        : WindowIdentity,
        parent             : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame
}

public extension ObservedSurfaceSourcing {
    /// A conformer must implement the measured crop operation. Capturing only
    /// the host would recreate the black-band mapping error this API exists to
    /// prevent, so source compatibility is a named refusal rather than a
    /// silently incorrect host still.
    func captureWindowRegionStill(
        host                : WindowIdentity,
        children            : [WindowIdentity],
        displayID           : CGDirectDisplayID,
        screenRect          : CGRect,
        sourceWindowFrame   : CGRect,
        observationBarrier  : UInt64,
        deadlineNanoseconds : UInt64
    ) async throws -> SeatFrame {
        throw ObservationUnavailable.capabilityUnqualified(.windowStill)
    }
}

/// UnqualifiedObservationSource is the source a seat gets when nothing was
/// composed for it: it supports nothing and captures nothing.
///
/// It exists so that a seat built without a capture path refuses observations
/// with a named capability instead of throwing something the consumer has to
/// parse, and so that no code path can reach a capture nobody configured.
nonisolated public struct UnqualifiedObservationSource: ObservedSurfaceSourcing {

    public init() {}

    public func supports(_ capability: ObservationCapability) -> Bool { false }

    public func captureWindowStill(
        of identity        : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {
        throw ObservationUnavailable.capabilityUnqualified(.windowStill)
    }

    public func captureWindowRegionStill(
        host                : WindowIdentity,
        children            : [WindowIdentity],
        displayID           : CGDirectDisplayID,
        screenRect          : CGRect,
        sourceWindowFrame   : CGRect,
        observationBarrier  : UInt64,
        deadlineNanoseconds : UInt64
    ) async throws -> SeatFrame {
        throw ObservationUnavailable.capabilityUnqualified(.windowStill)
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

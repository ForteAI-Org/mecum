//
//  SeatCaptureObservationSource.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
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
/// The dedicated surface of a transient menu is supported, and it is supported
/// because it was measured rather than assumed. The filter this module builds is
/// `SCContentFilter(desktopIndependentWindow:)`, and the open question was
/// whether aiming it at a menu window yields that menu's pixels with geometry a
/// coordinate transform can use. Both halves were read from an independent
/// process against a real Finder contextual menu on the Virtual Display: menu
/// window 42032 at layer 101, frame 255x463 pt at (3051,1378), the filter's own
/// content rectangle 255x463 pt at the same (3051,1378), `pointPixelScale` 1.0,
/// and captured content of 255x463 at (0,0) filling a 255x463 buffer, 100% of
/// its width and 100% of its height. Identical rectangle at an identical origin
/// makes the geometry usable; content that fills the buffer from its origin
/// makes the pixels the menu's own rather than a crop, a pad or a thumbnail. The
/// filter aimed at a menu window behaves as it does aimed at an ordinary window,
/// which is what the refusal was waiting to know.
///
/// That reading is of one menu family, AppKit's, through Finder. A Chromium menu
/// has not been read yet, so this qualification rests on the AppKit family and
/// claims nothing about a toolkit that draws its menus itself.
///
/// The content clock is supported by the host's separate
/// `MachAbsoluteContentClock`, which converts the documented WindowServer Mach
/// timestamp. A one-shot result that omits it is replaced by the first complete
/// stream frame carrying it. `FrameSampleQualifier` still refuses a malformed
/// timestamp, and a stream that cannot provide one expires inside the same
/// capture deadline.
///
/// That replacement passes no size. The window it is about to capture is the
/// window a placement may have resized a moment ago, and the first Still's
/// buffer is a measurement of an earlier instant: handing it to a stream that
/// builds its own fresh filter is how the agent came to perceive a picture with
/// a black band down one side. The size is the filter's, taken at start.
nonisolated public struct SeatCaptureObservationSource: ObservedSurfaceSourcing {

    private let displayGeneration: UInt64

    public init(displayGeneration: UInt64) {
        self.displayGeneration = displayGeneration
    }

    public func supports(_ capability: ObservationCapability) -> Bool {
        switch capability {
            case .windowStill     : true
            case .menuSurfaceStill: true
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
            displayGeneration: displayGeneration,
            timeout          : .nanoseconds(Int64(min(
                deadlineNanoseconds - afterStill,
                UInt64(Int64.max)
            )))
        )
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
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineNanoseconds > now else {
            throw ObservationUnavailable.captureDeadlineExpired(attemptsSpent: 0)
        }
        let target = SeatCaptureTarget.attestedWindowRegion(
            host              : host,
            children          : children,
            displayID         : displayID,
            screenRect        : screenRect,
            sourceWindowFrame : sourceWindowFrame
        )
        let remaining = Duration.nanoseconds(Int64(min(
            deadlineNanoseconds - now,
            UInt64(Int64.max)
        )))
        let still = try await SeatCaptureStream.still(
            of                : target,
            displayGeneration : displayGeneration,
            observationBarrier: observationBarrier,
            timeout           : remaining
        )
        guard still.displayTime == nil else { return still }
        let afterStill = DispatchTime.now().uptimeNanoseconds
        guard deadlineNanoseconds > afterStill else {
            throw ObservationUnavailable.captureDeadlineExpired(attemptsSpent: 1)
        }
        return try await SeatCaptureStream.timestampedStill(
            of               : target,
            displayGeneration: displayGeneration,
            timeout          : .nanoseconds(Int64(min(
                deadlineNanoseconds - afterStill,
                UInt64(Int64.max)
            )))
        )
    }

    /// Captures the menu's own dedicated surface.
    ///
    /// `parent` is unused here, and that is a decision rather than an oversight.
    /// The protocol carries it because the attribution of the observation is the
    /// parent's and because a conformer that could only reach a menu through the
    /// window it hangs off would need it. This one does not: the measurement
    /// above shows the filter aimed at the menu's own identity delivering the
    /// menu's own pixels with the menu's own frame, so there is nothing left for
    /// a parent-anchored transform to correct. The body is `captureWindowStill`
    /// because it is the same native call on the same kind of target, and
    /// spelling it out twice would only let the two drift apart.
    public func captureMenuStill(
        of identity        : WindowIdentity,
        parent             : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {
        try await captureWindowStill(
            of                 : identity,
            observationBarrier : observationBarrier,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }
}

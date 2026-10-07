//
//  SeatCaptureObservationSource.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import Dispatch
#if MECUM_PHASES
import PhaseSignposts
#endif
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
/// A system whose one-shot never carries the timestamp would capture and discard
/// a Still on every request, so `StillTimestampMemory` remembers the first miss of
/// this source's display generation and later requests start the stream at once.
///
/// That replacement passes no size. The window it is about to capture is the
/// window a placement may have resized a moment ago, and the first Still's
/// buffer is a measurement of an earlier instant: handing it to a stream that
/// builds its own fresh filter is how the agent came to perceive a picture with
/// a black band down one side. The size is the filter's, taken at start.
///
/// ## A stream that is already running
///
/// Starting that stream costs about 135 ms a Still (size 46, start 80, stop 8,
/// measured 7 October 2026). When the consumer composed `liveFrames`, a window
/// Still first asks it for a frame displayed after the request, within
/// `LiveFrameHandover.bound`, and hands it over only after `LiveFrameHandover`
/// accepts it against fresh window server readings, as a copy out of the
/// stream's pool. Any refusal takes the Still above. Hosted-sheet crops and
/// menu surfaces never use it: the running stream shows one window.
nonisolated public struct SeatCaptureObservationSource: ObservedSurfaceSourcing {

    private let displayGeneration: UInt64
    private let timestamps = StillTimestampMemory()
    private let displayID : CGDirectDisplayID?
    private let liveFrames: (any LiveWindowFrameSourcing)?

    /// `liveFrames` is borrowed for the source's life and `displayID` is the display whose scale
    /// a window's size is checked at; without both, every Still starts its own stream.
    public init(
        displayGeneration: UInt64,
        displayID        : CGDirectDisplayID? = nil,
        liveFrames       : (any LiveWindowFrameSourcing)? = nil
    ) {
        self.displayGeneration = displayGeneration
        self.displayID         = displayID
        self.liveFrames        = liveFrames
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
        if let liveFrames, let displayID {
            let answer = await liveFrame(
                of                 : identity,
                displayedAfter     : now,
                deadlineNanoseconds: deadlineNanoseconds,
                from               : liveFrames,
                readings           : { LiveFrameHandover.readings(of: $0, on: displayID) }
            )
            if case .success(let frame) = answer { return frame }
            #if MECUM_PHASES
            if case .failure(let fallback) = answer {
                PhaseInterval.event("capture.liveFallback", String(describing: fallback))
            }
            #endif
        }
        return try await stillOfOwnStream(
            of                 : identity,
            observationBarrier : observationBarrier,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    /// The Still path that starts its own stream (or takes a one-shot), unchanged by `liveFrames`.
    private func stillOfOwnStream(
        of identity        : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineNanoseconds > now else {
            throw ObservationUnavailable.captureDeadlineExpired(attemptsSpent: 0)
        }
        return try await capturedStill(
            of                 : .attestedWindow(identity),
            startedAt          : now,
            observationBarrier : observationBarrier,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    /// Asks `source` for a frame of `identity` displayed after `notBefore` and answers it, copied
    /// out of the stream's pool, only when `LiveFrameHandover` accepts it against `readings`
    /// taken after it arrived. The wait is the tighter of the bound and the request's deadline.
    func liveFrame(
        of identity             : WindowIdentity,
        displayedAfter notBefore: UInt64,
        deadlineNanoseconds     : UInt64,
        from source             : any LiveWindowFrameSourcing,
        readings                : (WindowIdentity) -> LiveFrameHandover.Readings
    ) async -> Result<SeatFrame, LiveFrameFallback> {

        #if MECUM_PHASES
        let phase = PhaseInterval.begin("capture.liveFrame")
        defer { phase.end() }
        #endif
        let remaining = deadlineNanoseconds > notBefore ? deadlineNanoseconds - notBefore : 0
        let bound = min(LiveFrameHandover.bound, .nanoseconds(Int64(min(remaining, UInt64(Int64.max)))))
        let answer = await source.liveFrame(of: identity, displayedAfter: notBefore, within: bound)
        guard case .success(let frame) = answer else { return answer }
        if let refusal = LiveFrameHandover.refusal(
            of            : frame,
            expected      : identity,
            displayedAfter: notBefore,
            readings      : readings(identity)
        ) {
            return .failure(refusal)
        }
        guard let copy = frame.detachedCopy() else { return .failure(.copyFailed) }
        return .success(copy)
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
        return try await capturedStill(
            of                 : target,
            startedAt          : now,
            observationBarrier : observationBarrier,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    /// Takes the one-shot Still, or skips it for a generation that missed the display time already,
    /// and answers a Frame that carries it. Both capture paths share this body, so they cannot
    /// disagree on when the stream is used.
    private func capturedStill(
        of target          : SeatCaptureTarget,
        startedAt now      : UInt64,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {

        try await timestamps.timestamped(
            generation: displayGeneration,
            oneShot   : {
                #if MECUM_PHASES
                let phase = PhaseInterval.begin("capture.oneShotStill")
                defer { phase.end() }
                #endif
                return try await SeatCaptureStream.still(
                    of                : target,
                    displayGeneration : displayGeneration,
                    observationBarrier: observationBarrier,
                    timeout           : Self.remaining(until: deadlineNanoseconds, from: now)
                )
            },
            fallback  : { attemptsSpent in
                let afterStill = DispatchTime.now().uptimeNanoseconds
                guard deadlineNanoseconds > afterStill else {
                    throw ObservationUnavailable.captureDeadlineExpired(attemptsSpent: attemptsSpent)
                }
                #if MECUM_PHASES
                let phase = PhaseInterval.begin("capture.streamStill")
                defer { phase.end() }
                #endif
                return try await SeatCaptureStream.timestampedStill(
                    of               : target,
                    displayGeneration: displayGeneration,
                    timeout          : Self.remaining(until: deadlineNanoseconds, from: afterStill)
                )
            }
        )
    }

    private static func remaining(until deadlineNanoseconds: UInt64, from now: UInt64) -> Duration {
        .nanoseconds(Int64(min(deadlineNanoseconds - now, UInt64(Int64.max))))
    }

    /// Captures the menu's own dedicated surface.
    ///
    /// `parent` is unused here, and that is a decision rather than an oversight.
    /// The protocol carries it because the attribution of the observation is the
    /// parent's and because a conformer that could only reach a menu through the
    /// window it hangs off would need it. This one does not: the measurement
    /// above shows the filter aimed at the menu's own identity delivering the
    /// menu's own pixels with the menu's own frame, so there is nothing left for
    /// a parent-anchored transform to correct. The body is the window Still's own
    /// stream path because it is the same native call on the same kind of target,
    /// and spelling it out twice would only let the two drift apart. It never asks
    /// `liveFrames`, which streams the window and not its menu.
    public func captureMenuStill(
        of identity        : WindowIdentity,
        parent             : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {
        try await stillOfOwnStream(
            of                 : identity,
            observationBarrier : observationBarrier,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }
}

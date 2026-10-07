//
//  LiveWindowFrameSourcing.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import SeatCapture
import SeatCore

/// LiveWindowFrameSourcing is a stream of the Adopted Window that is already running, offered to
/// observation so a Still does not have to start a stream of its own.
///
/// ## Why it is injected
///
/// The running stream belongs to whoever shows the window to the person (in Mecum, the Broker's
/// window preview), and observation belongs to the seat. The seat never reaches into that owner:
/// a consumer that has such a stream composes it here through `SeatHost.makeSeat(liveFrames:)`,
/// and a seat without one keeps starting a stream per Still.
///
/// ## Contract
///
/// A conformer answers the first complete Frame of `identity` that WindowServer displayed after
/// `notBefore`, an uptime instant in nanoseconds, waiting at most `bound`, or the reason it has
/// none. It declines rather than waits when it is not streaming that exact window right now:
/// another window, the whole display, a recovery, no stream at all. A stream at a rest rate it
/// wakes, and then waits for a frame displayed after the instant like any other (ADR 0036).
///
/// Nothing a conformer answers is trusted as evidence. `SeatCaptureObservationSource` attests the
/// window's identity, the display time, the window's rectangle and the frame's size again at the
/// hand-over, copies the pixels out of the stream's pool, and then the seat qualifies the Frame
/// as it qualifies every other one. A refusal there is a fallback to the stream Still, never an
/// observation failure.
@MainActor
public protocol LiveWindowFrameSourcing: AnyObject, Sendable {

    /// The first Frame of `identity` displayed after `notBefore`, or why there is none.
    func liveFrame(
        of identity             : WindowIdentity,
        displayedAfter notBefore: UInt64,
        within bound            : Duration
    ) async -> Result<SeatFrame, LiveFrameFallback>

    /// As `liveFrame(of:displayedAfter:within:)`, with a longer bound for a request that finds the
    /// stream at a rest rate and must wake it first. The default ignores it, for a source with no
    /// rest rate.
    func liveFrame(
        of identity              : WindowIdentity,
        displayedAfter notBefore : UInt64,
        within bound             : Duration,
        afterRestWithin restBound: Duration
    ) async -> Result<SeatFrame, LiveFrameFallback>
}

extension LiveWindowFrameSourcing {

    public func liveFrame(
        of identity              : WindowIdentity,
        displayedAfter notBefore : UInt64,
        within bound             : Duration,
        afterRestWithin restBound: Duration
    ) async -> Result<SeatFrame, LiveFrameFallback> {
        await liveFrame(of: identity, displayedAfter: notBefore, within: bound)
    }
}

/// LiveFrameFallback is why an observation took a stream Still instead of a frame of the running
/// stream. Every case falls back; none of them fails the observation on its own.
public enum LiveFrameFallback: Error, Equatable, Sendable {

    /// No running stream, or one still starting.
    case notLive

    /// The stream stopped and its bounded recovery is still trying.
    case recovering

    /// The stream was at a lower rate because nothing used it for a while. The request woke it
    /// and waited, but the wake was still unconfirmed and no frame displayed after the instant
    /// came within the bound; the Still is taken, and a later request finds the stream awake.
    case resting

    /// The person pinned the live picture to the whole display, and a display frame is never
    /// cropped into a window observation.
    case pinnedToDisplay

    /// The running stream shows another window or another capture family.
    case otherWindow

    /// No frame displayed after the instant arrived within the bound.
    case noFrameInBound

    /// The frame's display time is missing, malformed or not after the instant.
    case displayedBeforeInstant

    /// The window server no longer gives the window the identity the frame carries.
    case identityChanged

    /// The window is no longer at the rectangle the frame was certified with.
    case geometryChanged

    /// The frame's size is not the window's size at the display's scale: a band would be in it.
    case sizeMismatch

    /// The pixels could not be copied out of the stream's pool.
    case copyFailed
}

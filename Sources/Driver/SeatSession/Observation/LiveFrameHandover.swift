//
//  LiveFrameHandover.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import SeatCapture
import SeatCore
import WindowPlacement

/// LiveFrameHandover decides whether a Frame of a running window stream may stand in for a
/// stream Still, against readings taken at the hand-over.
///
/// ## The rule
///
/// The stream Still starts a stream after the request and takes its first complete Frame with a
/// display time, so its pixels were displayed after the request was made. A running stream is
/// held to the same instant explicitly: the Frame's display time, converted by
/// `MachAbsoluteContentClock` as the stream Still converts it, must be after the moment the
/// request reached the source. That moment is after the seat read its observation barrier, and so
/// after the last Command or invalidation that advanced it.
///
/// ## What it checks again, and why each check is here
///
/// - The Frame's source is the requested window lifetime, and the window server still gives that
///   window number this identity now: the stream's own per-frame check is cached for up to a
///   second, so it is not relied on.
/// - The window is at exactly the rectangle the Frame was certified with: the stream's rectangle
///   is cached too, and a moved window would map every coordinate wrongly.
/// - The Frame's buffer and the part of it the content filled both agree, within
///   `CaptureShapeStabilisation`'s tolerance, with the window's size at the display's scale. On
///   macOS 27 a frame's geometry is derived from the whole surface, so a stream still running at
///   an earlier shape would hand the agent a picture with a black band down one side, with nothing
///   in its geometry to show it. A reshape the stream has not taken yet is a mismatch.
///
/// Any refusal is a fallback to the stream Still. The seat then qualifies whichever Frame it gets
/// with `FrameSampleQualifier` and re-reads its situation after the capture, as for every Still.
nonisolated enum LiveFrameHandover {

    /// How long an observation waits for a frame of the running stream before taking a Still.
    /// Measured on 7 October 2026 at 30 fps, the first frame after an input came 17 to 34 ms
    /// later, so three frame intervals is the bound; a stream that misses it is not delivering.
    static let bound: Duration = .milliseconds(100)

    /// What the window server says about the window at the hand-over.
    struct Readings: Equatable {
        var identity    : WindowIdentity?
        var windowFrame : CGRect?
        var displayScale: CGFloat?
    }

    /// Reads the window's identity, its rectangle and the scale of `displayID` now.
    static func readings(of identity: WindowIdentity, on displayID: CGDirectDisplayID) -> Readings {
        let mode = CGDisplayCopyDisplayMode(displayID)
        let scale = mode.flatMap { $0.width > 0 ? CGFloat($0.pixelWidth) / CGFloat($0.width) : nil }
        return Readings(
            identity    : WindowIdentityWitness().identity(of: identity.windowNumber),
            windowFrame : WindowServerProbe.geometry(of: identity.windowNumber)?.frame,
            displayScale: scale
        )
    }

    /// Why `frame` may not be handed over as an observation of `expected`, or nil when it may.
    static func refusal(
        of frame                : SeatFrame,
        expected                : WindowIdentity,
        displayedAfter notBefore: UInt64,
        readings                : Readings,
        clock                   : MachAbsoluteContentClock = MachAbsoluteContentClock()
    ) -> LiveFrameFallback? {

        guard case .window(let source) = frame.source, source == expected else { return .otherWindow }
        guard readings.identity == expected else { return .identityChanged }
        guard let ticks = frame.displayTime,
              let displayedAt = clock.displayTimeNanoseconds(fromMachTicks: ticks),
              displayedAt > notBefore
        else { return .displayedBeforeInstant }
        guard let windowFrame = readings.windowFrame,
              frame.geometry.screenRect == windowFrame
        else { return .geometryChanged }
        guard let scale = readings.displayScale, scale.isFinite, scale > 0,
              let filled = frame.geometry.contentPixelSize
        else { return .sizeMismatch }
        let expectedSize = CGSize(width: windowFrame.width * scale, height: windowFrame.height * scale)
        guard CaptureShapeStabilisation.agree(frame.pixelSize, expectedSize),
              CaptureShapeStabilisation.agree(filled, expectedSize)
        else { return .sizeMismatch }
        return nil
    }
}

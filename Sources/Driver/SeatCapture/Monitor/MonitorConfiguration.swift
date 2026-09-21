//
//  MonitorConfiguration.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// MonitorOutput is the size the Monitor is captured at.
///
/// `backing` is the default and the one to use: it maps one captured pixel to
/// one pixel of the view's backing store, which is the objective definition of
/// a sharp preview on a Retina display. Against a fixed 960x540 upscaled by the
/// view it measured three points of CPU and nothing in memory for the zero-copy
/// pipeline, where the `CGImage` pipeline that is now gone cost thirteen points
/// and 22 MB.
///
/// `fixed` is for a consumer that has a reason to pin the size, a recording of
/// known dimensions for instance, and accepts that the view will resample it.
nonisolated public enum MonitorOutput: Sendable, Equatable {

    /// The view's size in points and its backing scale factor. The kit does not
    /// import AppKit, so the scale comes from the consumer, which is the only
    /// one that knows which screen its view is on.
    case backing(pointSize: CGSize, scale: CGFloat)

    /// An explicit pixel size.
    case fixed(CGSize)

    public var pixelSize: CGSize {
        switch self {
        case .backing(let pointSize, let scale):
            let factor = max(1, scale)
            return CGSize(
                width : max(1, (pointSize.width  * factor).rounded()),
                height: max(1, (pointSize.height * factor).rounded())
            )
        case .fixed(let size):
            return CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        }
    }
}

/// MonitorConfiguration is what the consumer asks the Monitor for: a pace and
/// an output size. The default is 60 fps at the view's backing size, which is
/// the pair measured at about 6 % of one core and under 10 MB.
///
/// The 120 level has a precondition the Monitor checks: the display has to
/// really run at 120 Hz. Asking for it on a 60 Hz display would measure 60 and
/// call it 120, which is the one answer worse than a refusal.
nonisolated public struct MonitorConfiguration: Sendable, Equatable {

    public let targetFrameRate: MonitorFrameRate
    public let output         : MonitorOutput

    public init(
        targetFrameRate: MonitorFrameRate = .sixty,
        output         : MonitorOutput
    ) {
        self.targetFrameRate = targetFrameRate
        self.output          = output
    }

    /// The top rung of the degradation ladder for this configuration.
    public var quality: MonitorQuality {
        MonitorQuality(frameRate: targetFrameRate)
    }

    /// The stream configuration for one rung of the ladder.
    public func captureConfiguration(for quality: MonitorQuality) -> SeatCaptureConfiguration {
        SeatCaptureConfiguration(
            pixelSize      : quality.pixelSize(from: output.pixelSize),
            framesPerSecond: quality.frameRate.rawValue
        )
    }

    /// How far a reading may sit from the size it is compared with and still
    /// count as the same size, in pixels of the delivered buffer.
    ///
    /// Two, and not zero, because two roundings sit between the request and the
    /// delivery: `MonitorQuality.pixelSize(from:)` rounds the rung's fraction,
    /// and ScreenCaptureKit delivers a size of its own choosing that the kit
    /// reads back from the pixel buffer rather than assumes. One pixel of black
    /// at an edge is that arithmetic and not a band, and a reconfiguration is
    /// not free, so chasing it would trade an edge nobody can see for a hitch
    /// in the preview everybody can.
    ///
    /// The figure lives in `CaptureShapeStabilisation`, which is the one place
    /// the rule is written; this name stays for the callers that had it.
    public static var contentPixelTolerance: CGFloat {
        CaptureShapeStabilisation.contentPixelTolerance
    }

    /// The configuration to run when the capture has settled at a shape other
    /// than the one the stream was configured for, or nil to leave it alone.
    ///
    /// `contentPixelSize` is `SeatCaptureStream.lastContentPixelSize` and
    /// `previousReading` is the reading before it, both taken on the consumer's
    /// heartbeat. **Two agreeing readings are the settle budget**, and they are
    /// a heartbeat apart rather than a frame apart for a measured reason: a
    /// window moved onto the Virtual Display is published shrinking from 1291
    /// by 949 points to 136 by 190 over 700 ms, and a rule that acted on one
    /// reading would reconfigure the stream through every intermediate shape of
    /// that animation. `SeatWatchdog.heartbeat` is one second, so two agreeing
    /// readings are at least a second of a shape that stopped moving, which the
    /// 700 ms of that measurement cannot fit inside.
    ///
    /// The answer carries the size **at the top rung** in a `fixed` output, and
    /// that is what makes it compose with the ladder: `captureConfiguration`
    /// multiplies the output by the rung's own fraction, so the next rung
    /// change asks for a fraction of the followed shape instead of reverting to
    /// the size the consumer first asked for.
    ///
    /// Whether the shape has settled and is worth following at all is
    /// `CaptureShapeStabilisation`, which the Lab's own preview stream asks the
    /// same question of. What is left here is the rebasing, which is the only
    /// part of it that belongs to the ladder.
    public func following(
        contentPixelSize: CGSize,
        previousReading : CGSize?,
        at quality      : MonitorQuality
    ) -> MonitorConfiguration? {

        guard quality.resolutionScale > 0,
              let settled = CaptureShapeStabilisation.settledShape(
                  running        : quality.pixelSize(from: output.pixelSize),
                  reading        : contentPixelSize,
                  previousReading: previousReading
              )
        else { return nil }

        let atTopRung = CGSize(
            width : settled.width  / quality.resolutionScale,
            height: settled.height / quality.resolutionScale
        )
        return MonitorConfiguration(
            targetFrameRate: targetFrameRate,
            output         : .fixed(atTopRung)
        )
    }
}

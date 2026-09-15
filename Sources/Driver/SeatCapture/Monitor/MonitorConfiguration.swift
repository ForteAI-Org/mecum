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
}

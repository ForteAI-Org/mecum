//
//  SeatCaptureConfiguration.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import SeatCore
import ScreenCaptureKit

/// SeatCaptureTarget is what a stream captures: the whole Virtual Display, for
/// the Monitor the person watches, or one Adopted Window, for observation.
///
/// A window filter is independent of occlusion, which is why the seat's own
/// capture uses it: a window on the Virtual Display is never in front of
/// anything, and the display filter would also show whatever else the seat has
/// on stage.
nonisolated public enum SeatCaptureTarget: Sendable, Equatable {

    case display(CGDirectDisplayID)
    case window(windowNumber: Int)
    case attestedWindow(WindowIdentity)

    /// sourceIdentity preserves the distinction between a display, an
    /// identity-bound window and a legacy raw Window ID on every Frame.
    public var sourceIdentity: FrameSourceIdentity {
        switch self {
        case .display(let displayID):
            .display(displayID)
        case .window(windowNumber: let windowNumber):
            .unverifiedWindow(windowNumber: windowNumber)
        case .attestedWindow(let identity):
            .window(identity)
        }
    }

    var windowNumber: Int? {
        switch self {
        case .display:
            nil
        case .window(windowNumber: let windowNumber):
            windowNumber
        case .attestedWindow(let identity):
            identity.windowNumber
        }
    }
}

/// SeatCaptureConfiguration is the size and pace of one stream, and the place
/// where the three ScreenCaptureKit defaults that are not what the
/// documentation says get overridden.
///
/// Read off a fresh `SCStreamConfiguration` on 26A5425a: `minimumFrameInterval`
/// is 1/60 and not "native", `queueDepth` is 8 and not 3, `pixelFormat` is
/// `420v` and not BGRA. The web documentation states the opposite of all three
/// and the runtime follows the SDK header (research note 05, section 12). None
/// of them is left to the default here, which is also what makes a benchmark
/// reproducible.
nonisolated public struct SeatCaptureConfiguration: Sendable, Equatable {

    /// The output size in pixels. For the Monitor this is the backing size of
    /// the view that shows it: mapping one captured pixel to one backing pixel
    /// is the objective definition of a sharp preview, and it measured three
    /// points of CPU against the upscaled 960x540.
    public let pixelSize: CGSize

    /// Frames per second, as a `minimumFrameInterval` of `1/framesPerSecond`.
    /// ScreenCaptureKit delivers only frames that changed, so this is a
    /// ceiling and never a promise.
    public let framesPerSecond: Int

    /// The pool depth, three surfaces, and not a parameter.
    ///
    /// Three is the number the zero-copy pipeline was measured with, and it is
    /// the number the one frame contract of `SeatFrame` is written against.
    /// Eight, the real default, would let a slow consumer hold a queue of stale
    /// frames the person then watches arrive late.
    public static let queueDepth = 3

    public init(pixelSize: CGSize, framesPerSecond: Int) {
        self.pixelSize       = pixelSize
        self.framesPerSecond = framesPerSecond
    }

    /// Builds the ScreenCaptureKit configuration. Not public and not
    /// `Sendable`: `SCStreamConfiguration` is a mutable ObjC class, so it is
    /// built and used in one isolated place and never passed between actors.
    func makeStreamConfiguration(for target: SeatCaptureTarget? = nil) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width                = Int(pixelSize.width.rounded())
        configuration.height               = Int(pixelSize.height.rounded())
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.queueDepth           = Self.queueDepth
        configuration.pixelFormat          = kCVPixelFormatType_32BGRA
        configuration.showsCursor          = false
        configuration.capturesAudio        = false
        configuration.captureResolution    = .best
        if target?.windowNumber != nil {
            configuration.ignoreShadowsSingleWindow    = true
            configuration.ignoreGlobalClipSingleWindow = true
        }
        return configuration
    }

    /// The configuration of a Still: the same pixel format and framing, and the
    /// two single-window flags the shot needs so that a window's shadow and the
    /// clipping against the screen edge do not become part of the pixels a
    /// consumer diffs.
    ///
    /// `framesPerSecond` is meaningless for a one-shot capture and is left at
    /// the stream's value rather than invented.
    func makeStillConfiguration() -> SCStreamConfiguration {
        let configuration = makeStreamConfiguration()
        configuration.ignoreShadowsSingleWindow    = true
        configuration.ignoreGlobalClipSingleWindow = true
        return configuration
    }
}

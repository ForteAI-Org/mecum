//
//  SeatFrame.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import IOSurface
import SeatCore
import ScreenCaptureKit
import WindowPlacement

/// SeatFrame is one captured image of the Virtual Display or of an Adopted
/// Window, handed over **without a copy**: the `IOSurface` behind it is the
/// same memory the window server composited into, and it goes straight into
/// `CALayer.contents`.
///
/// That is the whole reason this type is not a `CGImage`. Measured on the same
/// scene at 1920x1080 and 60 fps, converting every frame through
/// `CIContext.createCGImage` cost 42,2 % of one core and 78 MB against 6,2 %
/// and 7 MB for the surface. `makeCGImage()` is still here for a
/// consumer that needs pixels it can read, and it is on request precisely so
/// that nothing on the live path pays for it.
///
/// ## The one frame contract
///
/// The stream's pool is `queueDepth` 3, which is three surfaces for the whole
/// pipeline: the window server's producer, the frame in flight, and one spare.
/// A receiver therefore holds **at most one SeatFrame at a time**. Holding two
/// starves the producer, and holding a stack of them stops the capture: no type
/// enforces this, because a scoped type would forbid the legitimate case of
/// keeping the last frame while the next is being composed.
///
/// ## Sendable
///
/// `IOSurface` and `CVPixelBuffer` are not `Sendable`, and this struct is: the
/// frame crosses from the ScreenCaptureKit queue to the main actor exactly
/// once, and after that hop nothing writes to it. The surface's pixels are
/// written by the window server, not by the kit, and the receiver never writes
/// to a frame it was handed. That is the invariant `@unchecked` stands on.
nonisolated public struct SeatFrame: @unchecked Sendable {

    /// The surface the window server composited into. Assigning it to
    /// `CALayer.contents` is documented in the QuartzCore header and not on the
    /// web, which is why it is a Ledger row with a Host test behind it
    /// (research note 05, section 11).
    public let surface: IOSurface

    /// The same memory seen as a pixel buffer, always **32BGRA**: the kit sets
    /// `pixelFormat` explicitly because ScreenCaptureKit's real default is
    /// `420v` and a vision pipeline downstream needs a deterministic layout
    /// (research note 05, section 12).
    public let pixelBuffer: CVPixelBuffer

    /// The frame's own time, from the sample buffer.
    public let presentationTime: CMTime

    /// When the kit's callback first saw the frame, in `mach_absolute_time`
    /// ticks. Subtracting it from a later reading is how the callback to screen
    /// latency of spec section 8 is measured, and ticks are what the fence and
    /// the input driver already use.
    public let receivedAt: UInt64

    /// When WindowServer displayed the frame, in `mach_absolute_time` ticks.
    /// ScreenCaptureKit may omit this attachment, so consumers must keep the
    /// visible-sample time unknown rather than substitute the callback time.
    public let displayTime: UInt64?

    /// Which instance of the Virtual Display produced the frame. A display that
    /// went away and came back is a different generation, and a frame from the
    /// old one is dropped rather than presented: the pixels belong to a screen
    /// that no longer exists.
    public let displayGeneration: UInt64

    /// The display or exact window lifetime configured as the capture source.
    /// A legacy raw window target remains explicitly unverified here and can
    /// never be converted into input authority.
    public let source: FrameSourceIdentity

    /// The geometry and scales ScreenCaptureKit attached to this exact sample.
    /// Filter geometry is never substituted because it would describe what
    /// was requested rather than what WindowServer actually delivered.
    public let geometry: FrameGeometryObservation

    /// The frame's size in pixels, from the pixel buffer and not from the
    /// configuration: ScreenCaptureKit is free to hand back a size it rounded.
    public let pixelSize: CGSize

    /// Builds a frame from what ScreenCaptureKit delivered, or answers nil when
    /// the sample has no IOSurface path or complete geometry attachments.
    ///
    /// The `IOSurfaceRef` from CoreVideo and the `IOSurface` class are two
    /// distinct types in Swift with no bridge, so the cast is by hand and
    /// documented in research note 05, section 11.
    init?(
        sampleBuffer     : CMSampleBuffer,
        source           : FrameSourceIdentity,
        displayGeneration: UInt64,
        captureGeneration: UInt64,
        observedRevision : UInt64,
        capturesFullWindow: Bool,
        receivedAt       : UInt64
    ) {
        guard
            let pixelBuffer = sampleBuffer.imageBuffer,
            let surfaceRef  = CVPixelBufferGetIOSurface(pixelBuffer)
        else { return nil }

        let pixelSize = CGSize(
            width : CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let attachment = Self.frameAttachment(of: sampleBuffer)
        let version = GeometryObservationVersion(
            observerGeneration: captureGeneration,
            sequence          : observedRevision
        )
        // ponytail: ScreenCaptureKit on 26A428 hands over some windows' frames
        // (Slack) with no attachments, so the documented geometry is missing.
        // The frame is then certified from what the capture already knows:
        // the whole surface is the window, and the window server says where
        // the window is. Ceiling: a partially covered or cropped capture would
        // be mapped as if it were the full window; full-window filters only.
        guard let geometry = attachment.flatMap({
            Self.geometry(
                from             : $0,
                source           : source,
                pixelSize        : pixelSize,
                displayGeneration: displayGeneration,
                captureGeneration: captureGeneration,
                observedRevision : observedRevision,
                capturesFullWindow: capturesFullWindow
            )
        }) ?? Self.fallbackGeometry(
            source            : source,
            pixelSize         : pixelSize,
            version           : version,
            capturesFullWindow: capturesFullWindow
        )
        else { return nil }

        self.init(
            surface          : unsafeBitCast(surfaceRef.takeUnretainedValue(), to: IOSurface.self),
            pixelBuffer      : pixelBuffer,
            presentationTime : sampleBuffer.presentationTimeStamp,
            receivedAt       : receivedAt,
            displayTime      : attachment.flatMap(Self.displayTime),
            displayGeneration: displayGeneration,
            source           : source,
            geometry         : geometry
        )
    }

    init(
        surface          : IOSurface,
        pixelBuffer      : CVPixelBuffer,
        presentationTime : CMTime,
        receivedAt       : UInt64,
        displayTime      : UInt64? = nil,
        displayGeneration: UInt64,
        source           : FrameSourceIdentity,
        geometry         : FrameGeometryObservation
    ) {
        self.surface           = surface
        self.pixelBuffer       = pixelBuffer
        self.presentationTime  = presentationTime
        self.receivedAt        = receivedAt
        self.displayTime       = displayTime
        self.displayGeneration = displayGeneration
        self.source            = source
        self.geometry          = geometry
        self.pixelSize         = CGSize(
            width : CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }

    /// The ScreenCaptureKit attachment is the only timestamp documented as
    /// WindowServer display time. `presentationTime` has a different clock and
    /// is retained as sample provenance, never converted by inference.
    private static func frameAttachment(
        of sampleBuffer: CMSampleBuffer
    ) -> [SCStreamFrameInfo: Any]? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let attachment = attachments.first
        else { return nil }
        return attachment
    }

    private static func displayTime(in attachment: [SCStreamFrameInfo: Any]) -> UInt64? {
        guard let raw = attachment[.displayTime] as? NSNumber else { return nil }
        return raw.uint64Value
    }

    /// geometry accepts only the attachment values documented by
    /// ScreenCaptureKit. Missing or malformed geometry drops the sample, which
    /// is safer than certifying coordinates with filter or configuration data.
    private static func geometry(
        from attachment    : [SCStreamFrameInfo: Any],
        source             : FrameSourceIdentity,
        pixelSize          : CGSize,
        displayGeneration  : UInt64,
        captureGeneration  : UInt64,
        observedRevision   : UInt64,
        capturesFullWindow : Bool
    ) -> FrameGeometryObservation? {
        guard
            let screenRect   = rectangle(attachment[.screenRect]),
            let contentRect  = rectangle(attachment[.contentRect]),
            let scaleFactor  = (attachment[.scaleFactor] as? NSNumber)?.doubleValue,
            let contentScale = (attachment[.contentScale] as? NSNumber)?.doubleValue
        else { return nil }

        let geometry = FrameGeometryObservation(
            source              : source,
            screenRect          : screenRect,
            contentRectInSurface: contentRect,
            scaleFactor         : CGFloat(scaleFactor),
            contentScale        : CGFloat(contentScale),
            pixelSize           : pixelSize,
            version             : GeometryObservationVersion(
                observerGeneration: captureGeneration,
                sequence          : observedRevision
            ),
            capturesFullWindow  : capturesFullWindow
        )
        return geometry.isValid ? geometry : nil
    }

    /// Geometry for a frame that arrived without attachments: the surface is
    /// the whole source, whose screen rectangle the window server reports.
    /// Refuses when the pixel aspect does not match the source, because then
    /// the surface is not simply the source scaled.
    private static func fallbackGeometry(
        source            : FrameSourceIdentity,
        pixelSize         : CGSize,
        version           : GeometryObservationVersion,
        capturesFullWindow: Bool
    ) -> FrameGeometryObservation? {
        let screenRect: CGRect?
        switch source {
        case .display(let displayID):
            screenRect = CGDisplayBounds(displayID)
        case .window(let identity):
            screenRect = WindowServerProbe.geometry(of: identity.windowNumber)?.frame
        case .unverifiedWindow(let windowNumber):
            screenRect = WindowServerProbe.geometry(of: windowNumber)?.frame
        }
        guard let screenRect, screenRect.width > 0, screenRect.height > 0,
              pixelSize.width > 0, pixelSize.height > 0
        else { return nil }
        let scaleX = pixelSize.width / screenRect.width
        let scaleY = pixelSize.height / screenRect.height
        guard abs(scaleX - scaleY) <= max(0.02, 1 / screenRect.width) else { return nil }
        let geometry = FrameGeometryObservation(
            source              : source,
            screenRect          : screenRect,
            contentRectInSurface: CGRect(origin: .zero, size: screenRect.size),
            scaleFactor         : scaleX,
            contentScale        : 1,
            pixelSize           : pixelSize,
            version             : version,
            capturesFullWindow  : capturesFullWindow
        )
        return geometry.isValid ? geometry : nil
    }

    private static func rectangle(_ value: Any?) -> CGRect? {
        if let rectangle = value as? CGRect { return rectangle }
        return (value as? NSValue)?.rectValue
    }

    /// makeCGImage draws the frame's pixels into an image that owns its own
    /// copy, for a consumer that has to read them: a before and after diff, a
    /// screenshot in a report, a vision model.
    ///
    /// The copy is the point. The surfaces come from a pool of three and the
    /// window server writes into them again as soon as they are free, so an
    /// image that pointed at the surface would tear a few frames later.
    /// `CGContext.makeImage()` snapshots the bitmap, which is what makes the
    /// result safe to keep. The layout is the 32BGRA the stream asked for:
    /// little endian, alpha first and ignored.
    public func makeCGImage() -> CGImage? {

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard
            let base = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data            : base,
                width           : CVPixelBufferGetWidth(pixelBuffer),
                height          : CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow     : CVPixelBufferGetBytesPerRow(pixelBuffer),
                space           : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo      : CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return nil }

        return context.makeImage()
    }
}

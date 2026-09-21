//
//  FrameGeometryObservation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics

/// FrameSourceIdentity is the exact source a Frame was configured to capture.
/// A display never fabricates a window identity, and a legacy window number is
/// retained as explicitly unverified provenance rather than input authority.
nonisolated public enum FrameSourceIdentity: Sendable, Equatable, Hashable {

    /// Pixels from one exact CoreGraphics display.
    case display(CGDirectDisplayID)

    /// Pixels requested from one attested WindowServer window lifetime.
    case window(WindowIdentity)

    /// Pixels requested with a compatibility Window ID lacking authority.
    case unverifiedWindow(windowNumber: Int)
}

/// FrameGeometryObservation is ScreenCaptureKit's geometry attached to one
/// delivered Frame. `contentRect` is in points inside the output surface;
/// `screenRect` is the captured content in Quartz screen coordinates. Neither
/// rectangle is silently treated as pixels or substituted from the filter.
nonisolated public struct FrameGeometryObservation: Sendable, Equatable {

    /// The configured display or window source stamped on this sample.
    public let source              : FrameSourceIdentity

    /// The captured content's onscreen rectangle in Quartz points.
    public let screenRect          : CGRect

    /// The physical window whose identity supplied the capture source. A
    /// hosted-sheet frame may cover the attested host-and-sheet union while
    /// window-local input coordinates still belong to this host rectangle.
    public let sourceWindowFrame   : CGRect?

    /// The captured content's rectangle in points inside the output surface.
    public let contentRectInSurface: CGRect

    /// Backing pixels per point for the display that produced the sample.
    public let scaleFactor         : CGFloat

    /// The scale from original content size to its size in the surface.
    public let contentScale        : CGFloat

    /// The delivered pixel buffer's actual dimensions.
    public let pixelSize           : CGSize

    /// The observer-local revision assigned to this sample.
    public let version             : GeometryObservationVersion

    /// Whether the capture configuration excluded a window shadow and global
    /// screen-edge clipping. Ratios alone cannot prove that pixels represent
    /// the complete window.
    public let capturesFullWindow  : Bool

    /// Creates the immutable geometry metadata carried by one frame.
    public init(
        source              : FrameSourceIdentity,
        screenRect          : CGRect,
        sourceWindowFrame   : CGRect? = nil,
        contentRectInSurface: CGRect,
        scaleFactor         : CGFloat,
        contentScale        : CGFloat,
        pixelSize           : CGSize,
        version             : GeometryObservationVersion,
        capturesFullWindow  : Bool
    ) {
        self.source               = source
        self.screenRect           = screenRect
        self.sourceWindowFrame    = sourceWindowFrame
        self.contentRectInSurface = contentRectInSurface
        self.scaleFactor          = scaleFactor
        self.contentScale         = contentScale
        self.pixelSize            = pixelSize
        self.version              = version
        self.capturesFullWindow   = capturesFullWindow
    }

    /// isValid requires every value needed by a coordinate transform to be
    /// finite and positive, and the content rectangle to fit in the surface.
    /// A malformed value cannot become frame provenance or authorize a mouse
    /// Command.
    public var isValid: Bool {
        guard screenRect.hasFinitePositiveArea,
              sourceWindowFrame.map(\.hasFinitePositiveArea) ?? true,
              contentRectInSurface.hasFinitePositiveArea,
              pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0,
              scaleFactor.isFinite,
              scaleFactor > 0,
              contentScale.isFinite,
              contentScale > 0
        else { return false }

        let surfaceSize = CGSize(
            width : pixelSize.width / scaleFactor,
            height: pixelSize.height / scaleFactor
        )
        guard surfaceSize.width.isFinite, surfaceSize.height.isFinite else { return false }

        let surfaceRect = CGRect(origin: .zero, size: surfaceSize)
        let tolerance   = 1 / scaleFactor
        return contentRectInSurface.minX >= surfaceRect.minX - tolerance
            && contentRectInSurface.minY >= surfaceRect.minY - tolerance
            && contentRectInSurface.maxX <= surfaceRect.maxX + tolerance
            && contentRectInSurface.maxY <= surfaceRect.maxY + tolerance
    }

    /// contentPixelSize is how much of the delivered buffer the capture filled,
    /// in that buffer's own pixels.
    ///
    /// `pixelSize` is the buffer the stream was configured for and
    /// `contentRectInSurface` is the part of it WindowServer wrote, in points,
    /// so the two agree only while the source still has the shape the stream
    /// was started with. When they disagree the remainder of the buffer is
    /// black, and this is the size that black has to be removed by
    /// reconfiguring to. The conversion is the same one `isValid` and
    /// `MonitorLayer.contentsRect(of:)` use: the surface in points is
    /// `pixelSize` over `scaleFactor`.
    ///
    /// Nil for a geometry the transform rules already refuse, which is the
    /// answer `screenPoint(fromPixelPoint:)` gives such a frame too.
    ///
    /// The ceiling on every reader of this: a frame that arrived without
    /// ScreenCaptureKit attachments is certified from `fallbackGeometry`, which
    /// declares the content rectangle to be the whole surface by construction.
    /// Such a frame reports a full buffer whatever is in it, so black it
    /// carries is invisible here and in `MonitorLayer.contentsRect(of:)` alike.
    public var contentPixelSize: CGSize? {
        guard isValid else { return nil }
        return CGSize(
            width : contentRectInSurface.width  * scaleFactor,
            height: contentRectInSurface.height * scaleFactor
        )
    }

    /// hasUniformWindowMapping rejects crops and output transforms that cannot
    /// be represented by one scalar from window points to surface points.
    public var hasUniformWindowMapping: Bool {
        guard isValid else { return false }

        let horizontal = contentRectInSurface.width / screenRect.width
        let vertical   = contentRectInSurface.height / screenRect.height
        let tolerance  = max(1 / max(screenRect.width, screenRect.height), 0.000_001)
        return abs(horizontal - vertical) <= tolerance
            && abs(horizontal - contentScale) <= tolerance
    }

    /// windowObservation turns only an identity-bound full-window Frame into
    /// input geometry. Display frames and raw window-number captures cannot
    /// authorize input into an arbitrary window.
    public var windowObservation: WindowGeometryObservation? {
        guard case .window(let identity) = source,
              capturesFullWindow,
              hasUniformWindowMapping
        else { return nil }
        return WindowGeometryObservation(
            window     : WindowReference(
                identity: identity,
                frame   : sourceWindowFrame ?? screenRect
            ),
            scaleFactor: scaleFactor,
            version    : version
        )
    }

    /// screenPoint converts a point in captured-image pixels through the
    /// attachment-defined content rectangle. It refuses padding, NaN, overflow
    /// and nonuniform output scaling rather than guessing a crop convention.
    public func screenPoint(fromPixelPoint pixelPoint: CGPoint) -> CGPoint? {
        guard hasUniformWindowMapping,
              pixelPoint.x.isFinite,
              pixelPoint.y.isFinite,
              pixelPoint.x >= 0,
              pixelPoint.y >= 0,
              pixelPoint.x < pixelSize.width,
              pixelPoint.y < pixelSize.height
        else { return nil }

        let surfacePoint = CGPoint(
            x: pixelPoint.x / scaleFactor,
            y: pixelPoint.y / scaleFactor
        )
        guard surfacePoint.x.isFinite, surfacePoint.y.isFinite,
              surfacePoint.x >= contentRectInSurface.minX,
              surfacePoint.y >= contentRectInSurface.minY,
              surfacePoint.x < contentRectInSurface.maxX,
              surfacePoint.y < contentRectInSurface.maxY
        else { return nil }

        let horizontal = (surfacePoint.x - contentRectInSurface.minX)
            / contentRectInSurface.width
        let vertical = (surfacePoint.y - contentRectInSurface.minY)
            / contentRectInSurface.height
        let screenPoint = CGPoint(
            x: screenRect.minX + horizontal * screenRect.width,
            y: screenRect.minY + vertical * screenRect.height
        )
        guard screenPoint.x.isFinite, screenPoint.y.isFinite else { return nil }
        return screenPoint
    }
}

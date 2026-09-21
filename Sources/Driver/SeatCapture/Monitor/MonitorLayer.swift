//
//  MonitorLayer.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import QuartzCore
import SeatCore

/// MonitorLayer shows a `SeatFrame` by putting its `IOSurface` straight into
/// `contents`. That assignment is the whole zero-copy pipeline: no conversion,
/// no image object, no pixel ever read by the kit.
///
/// It is a `CALayer` and not a view. QuartzCore only, no AppKit: the `NSView`
/// belongs to the consumer, which puts this layer in a layer-backed one and
/// keeps whatever it draws on top, an activity badge or the agent's cursor.
///
/// The measured numbers behind the shape, at 1920x1080 and 60 fps on the
/// reference machine: 6,2 % of one core, 7 MB net, 0,46 ms from
/// callback to screen at p50, no coalesced frame. The pipeline it replaces,
/// `CVPixelBuffer` to `CIContext` to `CGImage` to `NSImageView`, cost 42,2 %
/// and 78 MB for the same scene.
///
/// `present` is `open` so a consumer can wrap it: measuring the callback to
/// screen latency from outside the kit needs exactly that, and the benchmark
/// that gates spec section 8 does it that way rather than making the kit carry
/// instrumentation on its hot path.
nonisolated open class MonitorLayer: CALayer {

    /// Builds a layer ready to receive frames.
    ///
    /// `contentsScale` is the backing scale of the screen the layer will be
    /// shown on. It is a parameter and not a lookup because the kit does not
    /// import AppKit and would have to guess.
    ///
    /// A convenience initializer on purpose: Core Animation builds its own
    /// copies of a layer through `init(layer:)` and its archived form through
    /// `init(coder:)`, and overriding either to add a designated initializer
    /// here would mean reimplementing both for nothing.
    public convenience init(contentsScale: CGFloat) {
        self.init()
        self.contentsScale = max(1, contentsScale)
        contentsGravity    = .resizeAspect
        masksToBounds      = true
        backgroundColor    = CGColor(gray: 0, alpha: 1)
    }

    /// When the callback delivered the presented sample, and when WindowServer
    /// said it was displayed.
    ///
    /// They are two clocks and they are kept apart: the first is a fact about
    /// delivery, the second is the only documented statement about the visual
    /// instant and is often absent. Nil display time means unknown, and the
    /// callback time is never put in its place.
    public private(set) var presentedReceivedAtNanoseconds: UInt64?
    public private(set) var presentedDisplayTime: UInt64?

    /// True when the image on this layer is no longer being refreshed. The
    /// layer's `contents` deliberately stays: a consumer marks it rather than
    /// blanking it, because a blank preview hides that the preview stopped.
    public private(set) var isStale = false

    /// Presents one frame, inside a transaction with actions disabled.
    ///
    /// The transaction is not decoration. Without `setDisableActions`, changing
    /// `contents` is an implicitly animated property: Core Animation would
    /// cross-fade every frame into the next, which at 60 fps is a blur and a
    /// GPU cost for something that has to be an instant replacement.
    ///
    /// A subclass that overrides this and does not call `super` takes over the
    /// staleness bookkeeping with it.
    open func present(_ frame: SeatFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents     = frame.surface
        contentsRect = Self.contentsRect(of: frame.geometry)
        CATransaction.commit()
        presentedReceivedAtNanoseconds = frame.receivedAt
        presentedDisplayTime           = frame.displayTime
        isStale                        = false
    }

    /// Which part of the surface the capture actually filled, in the unit
    /// coordinates `contentsRect` is written in.
    ///
    /// The surface is the size the stream was configured with, and a stream's
    /// size is fixed when it starts. ScreenCaptureKit does not stretch a source
    /// that no longer has that shape to fill it: it writes the content where it
    /// fits and leaves the rest of the buffer black. Measured on a window being
    /// moved onto the Virtual Display, where the window server publishes it
    /// shrinking from 1291 by 949 points to 136 by 190 over 700 ms while the
    /// window's own body never moves: for that stretch every frame carries a
    /// small picture in a large buffer, and drawing the whole surface put the
    /// black on the person's monitor.
    ///
    /// Nothing about it had to be inferred. The content rectangle arrives with
    /// every frame, in points inside the surface, which is why it is normalised
    /// against the surface in points and not against the pixel buffer. Both it
    /// and `contentsRect` put their origin at the top left, so no flip belongs
    /// here; `screenPoint(fromPixelPoint:)` is the same convention read the
    /// other way.
    ///
    /// A geometry the transform rules already refuse, or a rectangle that does
    /// not sit inside the unit square once normalised, answers the whole
    /// surface. This is a preview: showing too much is a worse answer than
    /// showing the wrong part, and neither is worth a crash.
    package static func contentsRect(of geometry: FrameGeometryObservation) -> CGRect {

        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard geometry.isValid else { return whole }

        let surface = CGSize(
            width : geometry.pixelSize.width  / geometry.scaleFactor,
            height: geometry.pixelSize.height / geometry.scaleFactor
        )
        guard surface.width > 0, surface.height > 0 else { return whole }

        let unit = CGRect(
            x     : geometry.contentRectInSurface.minX   / surface.width,
            y     : geometry.contentRectInSurface.minY   / surface.height,
            width : geometry.contentRectInSurface.width  / surface.width,
            height: geometry.contentRectInSurface.height / surface.height
        )
        guard unit.minX >= 0, unit.minY >= 0,
              unit.maxX <= 1, unit.maxY <= 1,
              unit.width > 0, unit.height > 0
        else { return whole }
        return unit
    }

    /// Marks what is on the layer as no longer live, without removing it. Called
    /// by the owner when the capture stopped or failed.
    ///
    /// These three properties are written by `present`, which the owning stream
    /// calls on the main actor, and by this method, which the Monitor calls on
    /// the main actor. That one writer is the whole synchronization rule.
    public func markStale() {
        isStale = presentedReceivedAtNanoseconds != nil
    }

    /// What this layer is showing, and how much is known about when it was true.
    public var presentation: MonitorPresentation {
        MonitorPresentation(
            isLive               : presentedReceivedAtNanoseconds != nil && !isStale,
            hasImage             : presentedReceivedAtNanoseconds != nil,
            receivedAtNanoseconds: presentedReceivedAtNanoseconds,
            displayTime          : presentedDisplayTime
        )
    }
}

//
//  MonitorLayer.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import QuartzCore

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
        contents = frame.surface
        CATransaction.commit()
        presentedReceivedAtNanoseconds = frame.receivedAt
        presentedDisplayTime           = frame.displayTime
        isStale                        = false
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

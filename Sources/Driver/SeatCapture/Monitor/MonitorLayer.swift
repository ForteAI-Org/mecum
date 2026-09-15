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

    /// Presents one frame, inside a transaction with actions disabled.
    ///
    /// The transaction is not decoration. Without `setDisableActions`, changing
    /// `contents` is an implicitly animated property: Core Animation would
    /// cross-fade every frame into the next, which at 60 fps is a blur and a
    /// GPU cost for something that has to be an instant replacement.
    open func present(_ frame: SeatFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = frame.surface
        CATransaction.commit()
    }
}

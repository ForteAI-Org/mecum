//
//  ControlStateReading.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics

/// ControlCandidate is one box a grouping pass takes for a stateful control, in the image's own
/// pixels, carrying the little the geometry knows about it: which family of control it looked
/// like, and whether it was assumed rather than seen.
///
/// It is what `ElementGrouper`'s candidate passes produce, narrowed to what a pixel reader needs.
public struct ControlCandidate: Sendable, Equatable {

    /// Which family the geometry took the box for. A toggle's state sits at a knob's side; a
    /// mark's, a checkbox or a radio, sits inside the control.
    public enum Shape: String, Sendable, Equatable {
        case toggle
        case mark
    }

    public var box: CGRect
    public var shape: Shape
    /// True for the grouper's unanchored-column fallback, a switch no pill was ever seen for. The
    /// reader must confirm the knob before it commits a state for one.
    public var isAssumed: Bool

    public init(box: CGRect, shape: Shape, isAssumed: Bool = false) {
        self.box       = box
        self.shape     = shape
        self.isAssumed = isAssumed
    }
}

/// ControlStateReading answers what a switch, a checkbox or a radio is set to from pixels alone:
/// the read for an application that exposes no accessibility state, where a scene would otherwise
/// name the control without ever saying whether it is on.
///
/// The two shape tests are the gates `ElementGrouper.toggleCandidates` and
/// `ElementGrouper.markCandidates` take, so the measured geometry of real controls stays with the
/// reader that measured it instead of hardening into a constant in the core.
///
/// `state` answers nil whenever the reader will not commit: a flat crop, an ambiguous one, a box
/// that turns out to be a logo. Nil is the honest answer and never a guess, because a wrong state
/// is worse than a missing one. A pixel state fills a gap, it never overrules an application that
/// answered for itself: accessibility only ever adds, and so does this.
///
/// A conformer reads the image during the call and holds no reference to it afterwards.
public protocol ControlStateReading: Sendable {

    /// True when the box could be a switch: the gate `ElementGrouper.toggleCandidates` takes.
    func isToggleShaped(_ box: CGRect) -> Bool

    /// True when the box could be a checkbox or a radio: the gate `markCandidates` takes.
    func isMarkShaped(_ box: CGRect) -> Bool

    /// The candidate's state, or nil when the pixels do not say.
    func state(of candidate: ControlCandidate, in image: CGImage) -> ControlState?
}

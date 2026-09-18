//
//  BrainDetection.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// BrainDetection is one detection from a scene in the brain's input form: kind, label (empty when
/// unlabeled), window-normalized bounds, and the control state when one was read.
public struct BrainDetection: Sendable, Equatable {

    public var kind: ElementKind
    public var label: String
    public var bounds: NormalizedRect
    public var state: ControlState?

    public init(kind: ElementKind, label: String, bounds: NormalizedRect, state: ControlState? = nil) {
        self.kind   = kind
        self.label  = label
        self.bounds = bounds
        self.state  = state
    }

    /// The detection a scene element makes: an unlabeled element contributes no label.
    public init(_ element: SceneElement) {
        self.init(
            kind  : element.kind,
            label : element.isUnlabeled ? "" : element.label,
            bounds: element.bounds,
            state : element.state
        )
    }

    /// True for a control or an icon, the kinds an anchor can hold.
    public var isInteractive: Bool { kind == .control || kind == .icon }
}

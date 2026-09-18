//
//  SceneElement.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation

/// SceneElement is one thing on a window, as a language model reads it: a stable identity, a
/// human label, a kind, a normalized position, and the state of a control.
///
/// The image-free boundary is a property of this type, not a runtime promise: it has no crop, no
/// hash, no accessibility path and no pixel field, so nothing that serializes a scene can leak one.
public struct SceneElement: Sendable, Equatable, Hashable {

    /// Digit-sensitive identity that survives a window resize: never a coordinate for a labeled
    /// element, a coarse grid cell for an unlabeled one (see `SceneIdentity`).
    public var id: String
    public var kind: ElementKind
    /// What the model names: the recognized text, the icon's taught label, or a placeholder when the
    /// element has no name yet. Never empty in a scene.
    public var label: String
    public var bounds: NormalizedRect
    /// The accessibility role when one is known.
    public var role: String?
    /// The state of a stateful control; nil for anything that carries no state.
    public var state: ControlState?
    /// True for an icon nobody has named yet: an honest coverage gap the map surfaces by its id.
    public var isUnlabeled: Bool
    /// A sibling-group tag with an ordinal, when a learned structure places this element in one.
    public var group: String?
    /// True when the label came from memory rather than this frame. The position is always live.
    public var isRecalled: Bool
    /// A learned, trusted affordance such as "click: toggles".
    public var does: String?
    /// The named window panel this element lives in, once a scene has been composed.
    public var section: String?

    public init(
        id         : String,
        kind       : ElementKind,
        label      : String,
        bounds     : NormalizedRect,
        role       : String? = nil,
        state      : ControlState? = nil,
        isUnlabeled: Bool = false,
        group      : String? = nil,
        isRecalled : Bool = false,
        does       : String? = nil,
        section    : String? = nil
    ) {
        self.id          = id
        self.kind        = kind
        self.label       = label
        self.bounds      = bounds
        self.role        = role
        self.state       = state
        self.isUnlabeled = isUnlabeled
        self.group       = group
        self.isRecalled  = isRecalled
        self.does        = does
        self.section     = section
    }
}

extension SceneElement: Codable {

    /// The wire keys are the ones scenes have always used, so a stored scene still decodes.
    private enum CodingKeys: String, CodingKey {
        case id, kind, label, role, state, group, does, section
        case bounds      = "pos"
        case isUnlabeled = "unlabeled"
        case isRecalled  = "recalled"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id         : try c.decode(String.self, forKey: .id),
            kind       : try c.decode(ElementKind.self, forKey: .kind),
            label      : try c.decode(String.self, forKey: .label),
            bounds     : try c.decode(NormalizedRect.self, forKey: .bounds),
            role       : try c.decodeIfPresent(String.self, forKey: .role),
            state      : try c.decodeIfPresent(ControlState.self, forKey: .state),
            isUnlabeled: try c.decodeIfPresent(Bool.self, forKey: .isUnlabeled) ?? false,
            group      : try c.decodeIfPresent(String.self, forKey: .group),
            isRecalled : try c.decodeIfPresent(Bool.self, forKey: .isRecalled) ?? false,
            does       : try c.decodeIfPresent(String.self, forKey: .does),
            section    : try c.decodeIfPresent(String.self, forKey: .section)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(label, forKey: .label)
        try c.encode(bounds, forKey: .bounds)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(state, forKey: .state)
        if isUnlabeled { try c.encode(true, forKey: .isUnlabeled) }
        try c.encodeIfPresent(group, forKey: .group)
        if isRecalled { try c.encode(true, forKey: .isRecalled) }
        try c.encodeIfPresent(does, forKey: .does)
        try c.encodeIfPresent(section, forKey: .section)
    }
}

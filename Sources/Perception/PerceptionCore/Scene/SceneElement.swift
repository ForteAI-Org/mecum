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
///
/// Two facts about where a label came from and where an element sits structurally
/// (`labelOrigin`, `collectionPath`) ride along for the living memory. They are facts about the
/// read, not about the scene: they are not encoded, they take no part in equality, hashing or the
/// token, and the brain reads an element through `BrainDetection`, which never looks at them. So
/// the wire format, a stored scene's round trip, a ghost verdict and the brain's identities are what
/// they were before the facts existed.
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
    /// The live field or dropdown value, distinct from the control's name.
    public var value: String?
    /// Native selection in UTF-16 units, when it fits the exact observed field value.
    public var selectedRange: NSRange?
    /// The application's enabled flag; nil means it did not expose availability.
    public var isEnabled: Bool?
    /// A named accessibility container path, independent of geometric panels and learned groups.
    public var container: String?
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
    /// The accessibility attribute the label was read from; nil for an element built from pixels.
    /// It says where the name came from, not that the name is a stable caption.
    public var labelOrigin: LabelOrigin?
    /// For a row of a table, list or outline and for everything inside that row: the structural
    /// path up to and including the collection. Nil outside any collection. A structural signature
    /// stops here, so a row's name, which is content, never enters one; `container` keeps the full
    /// path a model addresses the element by.
    public var collectionPath: String?

    public init(
        id         : String,
        kind       : ElementKind,
        label      : String,
        bounds     : NormalizedRect,
        role       : String? = nil,
        state      : ControlState? = nil,
        value      : String? = nil,
        selectedRange: NSRange? = nil,
        isEnabled  : Bool? = nil,
        container  : String? = nil,
        isUnlabeled: Bool = false,
        group      : String? = nil,
        isRecalled : Bool = false,
        does       : String? = nil,
        section    : String? = nil,
        labelOrigin   : LabelOrigin? = nil,
        collectionPath: String? = nil
    ) {
        self.id             = id
        self.kind           = kind
        self.label          = label
        self.bounds         = bounds
        self.role           = role
        self.state          = state
        self.value          = value
        self.selectedRange  = Self.validRange(selectedRange, value: value)
        self.isEnabled      = isEnabled
        self.container      = container
        self.isUnlabeled    = isUnlabeled
        self.group          = group
        self.isRecalled     = isRecalled
        self.does           = does
        self.section        = section
        self.labelOrigin    = labelOrigin
        self.collectionPath = collectionPath
    }
}

extension SceneElement {

    /// Equality over the scene's own facts, the native selection among them; the memory-side
    /// `labelOrigin` and `collectionPath` are left out, so a scene decodes equal to the one that
    /// was encoded.
    public static func == (lhs: SceneElement, rhs: SceneElement) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.label == rhs.label && lhs.bounds == rhs.bounds
            && lhs.role == rhs.role && lhs.state == rhs.state && lhs.value == rhs.value
            && lhs.selectedRange == rhs.selectedRange
            && lhs.isEnabled == rhs.isEnabled && lhs.container == rhs.container
            && lhs.isUnlabeled == rhs.isUnlabeled && lhs.group == rhs.group && lhs.isRecalled == rhs.isRecalled
            && lhs.does == rhs.does && lhs.section == rhs.section
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
        hasher.combine(label)
        hasher.combine(bounds)
        hasher.combine(role)
        hasher.combine(state)
        hasher.combine(value)
        hasher.combine(selectedRange)
        hasher.combine(isEnabled)
        hasher.combine(container)
        hasher.combine(isUnlabeled)
        hasher.combine(group)
        hasher.combine(isRecalled)
        hasher.combine(does)
        hasher.combine(section)
    }

    /// Rejects missing values, negative ranges, overflow and ranges outside this reading.
    static func validRange(_ range: NSRange?, value: String?) -> NSRange? {
        guard let range, let value, range.location >= 0, range.length >= 0 else { return nil }
        let count = value.utf16.count
        guard range.location <= count, range.length <= count - range.location else { return nil }
        return range
    }
}

extension SceneElement: Codable {

    /// The wire keys are the ones scenes have always used, so a stored scene still decodes. The
    /// memory-only facts (`labelOrigin`, `collectionPath`) have no key: they are never encoded.
    private enum CodingKeys: String, CodingKey {
        case id, kind, label, role, state, value, selectedRange, isEnabled, container, group, does, section
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
            value      : try c.decodeIfPresent(String.self, forKey: .value),
            selectedRange: try c.decodeIfPresent(NSRange.self, forKey: .selectedRange),
            isEnabled  : try c.decodeIfPresent(Bool.self, forKey: .isEnabled),
            container  : try c.decodeIfPresent(String.self, forKey: .container),
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
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(Self.validRange(selectedRange, value: value), forKey: .selectedRange)
        try c.encodeIfPresent(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(container, forKey: .container)
        if isUnlabeled { try c.encode(true, forKey: .isUnlabeled) }
        try c.encodeIfPresent(group, forKey: .group)
        if isRecalled { try c.encode(true, forKey: .isRecalled) }
        try c.encodeIfPresent(does, forKey: .does)
        try c.encodeIfPresent(section, forKey: .section)
    }
}

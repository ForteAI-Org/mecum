import Foundation

/// The Accessibility view of a picked element: a replayable path from window → leaf, plus leaf attrs.
///
/// `available` is `false` when the click landed on an opaque group / GPU-painted canvas (Pro Tools,
/// Blender) where AX exposes nothing useful — the builder then falls through to the CV path.
public struct AXDescriptor: Codable, Equatable, Sendable {
    public var available: Bool
    public var path: [AXPathStep]      // root window → leaf
    public var leafAttrs: AXLeafAttrs?

    public init(available: Bool, path: [AXPathStep], leafAttrs: AXLeafAttrs?) {
        self.available = available
        self.path = path
        self.leafAttrs = leafAttrs
    }
}

/// One hop in the AX path. Carries multiple redundant ways to re-identify the element so a hit
/// survives reordering, retitling, and the title-vs-description split between apps.
public struct AXPathStep: Codable, Equatable, Sendable {
    public var role: String                 // kAXRoleAttribute
    public var title: String?               // kAXTitleAttribute
    public var titleRegex: String?          // optional, for volatile titles
    public var identifier: String?          // kAXIdentifierAttribute (often nil)
    public var descriptionText: String?     // kAXDescriptionAttribute — Logic Pro relies on this
    /// Index among SAME-ROLE siblings (not absolute child index) — far more stable across reorders.
    public var index: Int?
    public var siblingContext: SiblingContext?

    public init(
        role: String,
        title: String? = nil,
        titleRegex: String? = nil,
        identifier: String? = nil,
        descriptionText: String? = nil,
        index: Int? = nil,
        siblingContext: SiblingContext? = nil
    ) {
        self.role = role
        self.title = title
        self.titleRegex = titleRegex
        self.identifier = identifier
        self.descriptionText = descriptionText
        self.index = index
        self.siblingContext = siblingContext
    }
}

/// Titles of the immediately-adjacent same-role siblings, used to disambiguate after reordering.
public struct SiblingContext: Codable, Equatable, Sendable {
    public var prevTitle: String?
    public var nextTitle: String?

    public init(prevTitle: String? = nil, nextTitle: String? = nil) {
        self.prevTitle = prevTitle
        self.nextTitle = nextTitle
    }
}

/// Attributes of the leaf element, matched against the live element after path replay.
public struct AXLeafAttrs: Codable, Equatable, Sendable {
    public var role: String
    public var title: String?
    public var descriptionText: String?
    public var enabled: Bool?
    public var actions: [String]            // e.g. ["AXPress"]

    public init(role: String, title: String? = nil, descriptionText: String? = nil, enabled: Bool? = nil, actions: [String] = []) {
        self.role = role
        self.title = title
        self.descriptionText = descriptionText
        self.enabled = enabled
        self.actions = actions
    }
}

import Foundation
import CoreGraphics

/// One element in a text SCENE — the image-free view an LLM consumes instead of a screenshot. Carries only
/// a stable id, a human-meaningful `label`, a kind, a normalized position, and (for controls) state. It has
/// NO crop / edge-hash / AX-path / pixel field by construction — the image-free boundary is a type property,
/// not a runtime promise.
public struct SceneElement: Codable, Equatable, Sendable {
    public var id: String                 // stable identityKey (digit-sensitive; never a coordinate)
    public var kind: String               // "text" | "icon" | "control"
    public var label: String              // OCR text, icon-DB label, or "(unlabeled)" — what the LLM names
    public var pos: [Double]              // [x, y, w, h], window-normalized 0..1 (disambiguation only)
    public var role: String?              // AX role when known
    public var state: String?             // "on" | "off" | "unknown" for a stateful control
    /// Accessibility value, kept distinct from the label that identifies a control.
    public var value: String?
    public var unlabeled: Bool?           // true for an icon with no label yet (an honest coverage gap)
    public var group: String?             // brain sibling-group tag, e.g. "Destinations#3" (ordinal identity)
    public var recalled: Bool?            // true when the LABEL came from the brain (position is always live)
    public var does: String?              // trusted learned affordances, e.g. "click: toggles" (evidence ≥ 2)
    public var section: String?           // named window PANEL this element lives in ("TRACKS", "CLIPS")

    public init(id: String, kind: String, label: String, pos: [Double],
                role: String? = nil, state: String? = nil, value: String? = nil, unlabeled: Bool? = nil,
                group: String? = nil, recalled: Bool? = nil, does: String? = nil, section: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.pos = pos
        self.role = role; self.state = state; self.value = value; self.unlabeled = unlabeled
        self.group = group; self.recalled = recalled; self.does = does; self.section = section
    }
}

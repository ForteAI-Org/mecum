import CoreGraphics
import Foundation

/// How long each stage of one observation took. Shown in the lab so a slow
/// step can be named rather than guessed.
public struct PerceptionTiming: Sendable, Hashable {
    /// The still capture of the window.
    public var capture: Duration = .zero
    /// The whole scene pipeline: text recognition, segmentation, the
    /// accessibility read and composition. They run concurrently inside it and
    /// no stage has a duration of its own, so this is the one figure.
    public var detection: Duration = .zero
    /// Unfilled since perception became the Perception layer's pipeline, which
    /// does not time its stages apart. Kept so a reader of this type still
    /// compiles; a zero stage is left out of `summary` rather than printed.
    public var accessibility: Duration = .zero
    /// Unfilled, like `accessibility`.
    public var composition: Duration = .zero

    public var total: Duration { capture + detection + accessibility + composition }

    public init() {}

    public var summary: String {
        func s(_ d: Duration) -> String {
            String(format: "%.2fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        let stages = [("capture", capture), ("perception", detection),
                      ("ax", accessibility), ("compose", composition)]
        return ([s(total)] + stages.filter { $0.1 != .zero }.map { "\($0.0) \(s($0.1))" })
            .joined(separator: " · ")
    }
}

/// What the runtime perceived in one captured frame of the adopted window.
/// `image` is the frame the elements were measured on; `bounds` are normalized
/// to it (0...1), so an element can be drawn on the image and clicked in it.
public struct SceneObservation: @unchecked Sendable, Identifiable {
    /// The element type of `elements`, spellable where another module's
    /// `SceneElement` is in scope too.
    public typealias Element = SceneElement

    public let id: UUID
    public let capturedAt: Date
    public let image: CGImage
    public let elements: [SceneElement]
    /// Compact text for a model or a human: the numbered scene map.
    public let text: String
    /// Process-stable fingerprint of the element set; equal tokens mean nothing changed.
    public let token: String
    public let timing: PerceptionTiming?

    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    public init(id: UUID = UUID(), capturedAt: Date = .now, image: CGImage,
                elements: [SceneElement], text: String, token: String, timing: PerceptionTiming? = nil) {
        self.id = id
        self.capturedAt = capturedAt
        self.image = image
        self.elements = elements
        self.text = text
        self.token = token
        self.timing = timing
    }
}

/// One perceived UI element. `index` is 1-based and valid for exactly one
/// observation: it is what an action refers to.
public struct SceneElement: Sendable, Hashable, Identifiable {
    public let index: Int
    /// Unique inside one observation, which `id` has to be and `identity` is
    /// not: two unlabeled elements in the same coarse cell share one identity
    /// key, and a view keyed on that draws them as one row.
    public var id: Int { index }
    /// The Perception layer's own key for this element: stable across frames,
    /// shared between elements a frame cannot tell apart. What a before/after
    /// reading names its target by, never what a list is keyed on.
    public let identity: String
    public let kind: String
    public let label: String
    public let role: String?
    public let state: String?
    /// Accessibility value, separate from the human-facing control label.
    public let value: String?
    /// Normalized to the observation image, origin top-left.
    public let bounds: CGRect

    public init(index: Int, identity: String, kind: String, label: String,
                role: String?, state: String?, value: String? = nil, bounds: CGRect) {
        self.index = index
        self.identity = identity
        self.kind = kind
        self.label = label
        self.role = role
        self.state = state
        self.value = value
        self.bounds = bounds
    }

    /// Center of the element in image pixels.
    public func center(in pixelSize: CGSize) -> CGPoint {
        CGPoint(x: bounds.midX * pixelSize.width, y: bounds.midY * pixelSize.height)
    }
}

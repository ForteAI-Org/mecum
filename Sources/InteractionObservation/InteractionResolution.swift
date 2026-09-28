import CoreGraphics
import Foundation
import InteractionListener
import PerceptionCore

/// InteractionResolution describes a point hit in a scene sampled before input.
/// Candidates preserve their AX roles, states and values. Pixel geometry is evidence of a hit,
/// not proof of clickability; a separate name lookup checks the production action resolver.
public struct InteractionResolution: Sendable, Codable, Equatable {
    public let status: String
    public let element: SceneElement?
    public let candidates: [SceneElement]
    public let section: String?
    public let sceneAgeMilliseconds: Double?
    public let nameResolution: String?

    public static func missing(_ reason: String) -> Self {
        Self(status: reason, element: nil, candidates: [], section: nil, sceneAgeMilliseconds: nil, nameResolution: nil)
    }

    public static func resolve(
        event: InteractionEvent, sample: InteractionSample?, maximumAge: Double = 2
    ) -> Self {
        guard let sample else { return .missing("no_before_scene") }
        guard sample.window == event.window else { return .missing("different_window") }
        guard sample.revision == event.precedingRevision else { return .missing("intervening_input") }
        let age = event.startedAt - sample.startedAt
        guard sample.completedAt <= event.startedAt, age >= 0, age <= maximumAge else {
            return .missing("stale_before_scene")
        }
        let frame = sample.window.frame
        guard frame.width > 0, frame.height > 0, frame.contains(event.point) else {
            return .missing("point_outside_window")
        }
        let point = CGPoint(x: (event.point.x - frame.minX) / frame.width,
                            y: (event.point.y - frame.minY) / frame.height)
        return at(point: point, in: sample.scene, ageMilliseconds: age * 1000)
    }

    /// Uses identical native/control precedence for before and after point observations.
    static func at(point: CGPoint, in scene: SceneSnapshot, ageMilliseconds: Double? = nil) -> Self {
        let candidates = scene.elements.filter { $0.bounds.contains(point) }.sorted {
            let left = rank($0), right = rank($1)
            if left != right { return left < right }
            if $0.bounds.area != $1.bounds.area { return $0.bounds.area < $1.bounds.area }
            return $0.id < $1.id
        }
        let first = candidates.first
        let ambiguous = first.map { first in
            candidates.dropFirst().contains {
                rank($0) == rank(first) && abs($0.bounds.area - first.bounds.area) < 0.000001 && $0.id != first.id
            }
        } ?? false
        let chosen = ambiguous ? nil : first
        let named: String? = chosen.map { element in
            switch scene.resolve(target: element.label, preferNativeControls: true) {
            case .found(let match): match.id == element.id ? "same_element" : "different_element"
            case .ambiguous(let count): "ambiguous(\(count))"
            case .none: "not_found"
            }
        }
        return Self(
            status: ambiguous ? "ambiguous" : first == nil ? "no_element" : "resolved",
            element: chosen, candidates: Array(candidates.prefix(8)), section: scene.section(at: point)?.name,
            sceneAgeMilliseconds: ageMilliseconds, nameResolution: named
        )
    }

    private static func rank(_ element: SceneElement) -> Int {
        if AccessibilityAugmentation.interactiveRoles.contains(element.role ?? "") { return 0 }
        if element.kind == .control { return 1 }
        if element.kind == .icon { return 2 }
        if element.kind == .text { return 3 }
        return 4
    }
}

/// InteractionSample records the entire acquisition interval and input revision of one exact window.
/// Both bounds and window identity must still agree before its coordinates can label a later click.
public struct InteractionSample: Sendable {
    public let window: InteractionWindow
    public let scene: SceneSnapshot
    public let revision: UInt64
    public let startedAt: Double
    public let completedAt: Double

    public init(window: InteractionWindow, scene: SceneSnapshot, revision: UInt64, startedAt: Double, completedAt: Double) {
        self.window = window
        self.scene = scene
        self.revision = revision
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

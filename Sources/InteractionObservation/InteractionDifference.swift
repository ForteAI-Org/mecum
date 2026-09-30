import CoreGraphics
import Foundation
import InteractionListener
import PerceptionCore

/// InteractionDifference reports repeated observations, never an attributed action effect.
/// Two non-overlapping post-input acquisitions must share a window and uninterrupted revision.
/// Labels are not rewritten or propagated into the scene; uncertain OCR changes are suppressed.
public struct InteractionDifference: Sendable, Codable, Equatable {
    public let status: String
    public let appeared: [String]
    public let disappeared: [String]
    public let windowTitle: String?
    public let stateChanges: [String]

    static func sameSurface(_ first: InteractionWindow, _ second: InteractionWindow) -> Bool {
        first.number == second.number && first.processID == second.processID
            && first.frame == second.frame && first.layer == second.layer
    }

    static func needsConfirmation(before: InteractionSample, after: InteractionSample) -> Bool {
        before.scene.windowTitle != after.scene.windowTitle
            || !fresh(in: after.scene, absentFrom: before.scene).isEmpty
            || !fresh(in: before.scene, absentFrom: after.scene).isEmpty
            || !stateChanges(before: before.scene, after: after.scene).isEmpty
    }

    static func compare(
        before: InteractionSample,
        after: InteractionSample,
        confirmation: InteractionSample
    ) -> Self {
        guard sameSurface(before.window, after.window), sameSurface(after.window, confirmation.window),
              before.completedAt <= after.startedAt, after.completedAt <= confirmation.startedAt,
              after.revision == confirmation.revision,
              before.revision <= after.revision else {
            return Self(status: "not_comparable", appeared: [], disappeared: [], windowTitle: nil, stateChanges: [])
        }
        let appeared = fresh(in: after.scene, absentFrom: before.scene).filter {
            counterpart($0, in: confirmation.scene.elements) != nil
        }
        let disappeared = fresh(in: before.scene, absentFrom: after.scene).filter { element in
            !confirmation.scene.elements.contains { overlaps(element, $0) || key($0.label) == key(element.label) }
        }
        let title = before.scene.windowTitle != after.scene.windowTitle
            && after.scene.windowTitle == confirmation.scene.windowTitle ? after.scene.windowTitle : nil
        let states = stateChanges(before: before.scene, after: after.scene).filter {
            stateChanges(before: before.scene, after: confirmation.scene).contains($0)
        }
        let changed = !appeared.isEmpty || !disappeared.isEmpty || title != nil || !states.isEmpty
        return Self(status: changed ? "observed_consistently" : "no_consistent_change",
                    appeared: names(appeared), disappeared: names(disappeared), windowTitle: title, stateChanges: states)
    }

    private static func key(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func overlaps(_ first: SceneElement, _ second: SceneElement) -> Bool {
        let intersection = first.bounds.cgRect.intersection(second.bounds.cgRect)
        let area = min(first.bounds.area, second.bounds.area)
        return !intersection.isNull && area > 0 && intersection.width * intersection.height / area > 0.6
    }

    private static func counterpart(_ element: SceneElement, in elements: [SceneElement]) -> SceneElement? {
        let matches = elements.filter {
            key($0.label) == key(element.label) && $0.role == element.role
                && $0.kind == element.kind && $0.container == element.container && overlaps(element, $0)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func fresh(in scene: SceneSnapshot, absentFrom other: SceneSnapshot) -> [SceneElement] {
        scene.elements.filter { element in
            !element.isUnlabeled && !element.isRecalled && LabelText.isStableLabel(element.label)
                && !other.elements.contains { key($0.label) == key(element.label) || overlaps(element, $0) }
        }
    }

    private static func stateChanges(before: SceneSnapshot, after: SceneSnapshot) -> [String] {
        before.elements.compactMap { element in
            guard element.role != nil, let old = element.state,
                  let next = counterpart(element, in: after.elements)?.state, old != next else { return nil }
            return "\(element.label): \(old.rawValue) -> \(next.rawValue)"
        }.sorted()
    }

    private static func names(_ elements: [SceneElement]) -> [String] {
        Array(Set(elements.map(\.label)).sorted().prefix(8))
    }
}

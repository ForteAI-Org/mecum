import InteractionListener
import PerceptionCore

/// InteractionReport is the diagnostic stream consumed by a CLI or a future host.
/// The before hit, current AX hit and after hit remain separate because input can replace the UI.
/// A visual difference is an observation, not a learned causal claim or a verified agent action.
public struct InteractionReport: Sendable, Codable {
    public let event: InteractionEvent
    public let app: String
    public let bundleID: String?
    public let before: InteractionResolution
    public let afterElement: SceneElement?
    public let afterStatus: String
    public let observation: InteractionDifference?
    public let accessibility: AccessibilityPointResult?

    public init(
        event: InteractionEvent, app: String, bundleID: String?, before: InteractionResolution,
        afterElement: SceneElement?, afterStatus: String, accessibility: AccessibilityPointResult?,
        observation: InteractionDifference? = nil
    ) {
        self.event = event
        self.app = app
        self.bundleID = bundleID
        self.before = before
        self.afterElement = afterElement
        self.afterStatus = afterStatus
        self.observation = observation
        self.accessibility = accessibility
    }
}

/// AccessibilityPointResult is a bounded native hit test taken after event delivery.
/// Display text may supply a name; editable and secure values are excluded.
/// It never substitutes for a missing pre-click scene.
public struct AccessibilityPointResult: Sendable, Codable {
    public let status: String
    public let role: String?
    public let label: String?
    public let processID: Int32?
    public let labelSource: String?

    public init(status: String, role: String? = nil, label: String? = nil, processID: Int32? = nil,
                labelSource: String? = nil) {
        self.status = status
        self.role = role
        self.label = label
        self.processID = processID
        self.labelSource = labelSource
    }
}

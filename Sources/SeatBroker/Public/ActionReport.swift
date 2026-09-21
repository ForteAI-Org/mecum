import Foundation

/// What happened when one action was executed: the observation it was planned
/// on, the observation taken after it, and the verification between the two.
public struct ActionReport: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let action: SemanticAction
    public let targetLabel: String
    public let before: SceneObservation
    /// The scene perceived after the action, and nil when none could be: a
    /// Command that went out and whose reading was then refused still has a
    /// report, because what it did is not undone by nobody having looked.
    public let after: SceneObservation?
    public let verification: VerificationResult
    public let eventCount: Int
    public let duration: Duration

    /// What the action itself came to, when the verification cannot say it.
    /// A contextual menu is the case that needs it: which item was chosen, or
    /// why none was, is not a before/after difference, and a refusal by title
    /// changes no pixel at all. Nil for every action whose whole outcome the
    /// verification already describes.
    public let note: String?

    public init(action: SemanticAction, targetLabel: String, before: SceneObservation,
                after: SceneObservation?, verification: VerificationResult,
                eventCount: Int, duration: Duration, note: String? = nil) {
        self.action = action
        self.targetLabel = targetLabel
        self.before = before
        self.after = after
        self.verification = verification
        self.eventCount = eventCount
        self.duration = duration
        self.note = note
    }
}

/// Before/after comparison. `outcome` is what the Command came to and the one
/// field a reader should believe; `sceneChanged`, `effect` and
/// `pixelDifference` are the measurements under it. `effect` is the Locator
/// scene diff family when one was detected (title change, state flip, menu
/// opened, elements appeared or disappeared); `pixelDifference` is the mean
/// absolute pixel delta 0...1, nil when it could not be measured.
///
/// The three measurements never promote themselves: a scene that changed is a
/// scene that changed, and only the outcome says whether the action did what
/// it was for.
public struct VerificationResult: Sendable, Hashable {
    public let outcome: ActionOutcome
    public let sceneChanged: Bool
    public let effect: String?
    public let pixelDifference: Double?

    public init(outcome: ActionOutcome, sceneChanged: Bool, effect: String?, pixelDifference: Double?) {
        self.outcome = outcome
        self.sceneChanged = sceneChanged
        self.effect = effect
        self.pixelDifference = pixelDifference
    }

    public var summary: String {
        var parts = [outcome.sentence]
        if let effect { parts.append(effect) }
        if let pixelDifference { parts.append(String(format: "pixels %.1f%%", pixelDifference * 100)) }
        return parts.joined(separator: " · ")
    }
}

import CoreGraphics
import EngineCore
import PerceptionCore
import SeatCore

/// What one action's Command came to, as evidence and never as optimism.
///
/// The five are a ladder over one Command, and the rung is chosen by what was
/// read rather than by what was hoped for. A background that repainted is
/// `sceneChanged` and not a dialog that closed: the lab used to call that a
/// completed click, which is the whole reason this type exists.
public enum ActionOutcome: String, Sendable, Hashable, Codable {

    /// Nothing went out. The seat refused the Command before its first event,
    /// so there is no effect to look for. A refusal is never an executed
    /// action, however far the preparation got.
    case notObserved

    /// It went out and the reading afterwards found nothing changed.
    case posted

    /// It went out and something moved that the oracle does not cover.
    /// It is a measurement, not a verification: OCR, a repaint, a caret.
    case sceneChanged

    /// The oracle derived from the action and the surface holds.
    case expectedEffectVerified

    /// It went out and the reading that would settle it could not be taken.
    /// The effect is uncertain, so nothing repeats it.
    case interruptedAfterPost

    /// True while nobody can say what the Command did. The planner neither
    /// repeats one of these nor carries on with the rest of its plan on it.
    public var isUncertain: Bool { self == .interruptedAfterPost }

    /// True only for the one outcome that proves the action did what it was
    /// for. Everything a person or a record counts as verified counts this.
    public var isVerified: Bool { self == .expectedEffectVerified }

    /// The SF Symbol beside the step. Only the verified outcome gets a tick:
    /// a scene that changed used to get the same one.
    public var symbol: String {
        switch self {
        case .expectedEffectVerified: "checkmark.circle.fill"
        case .interruptedAfterPost:   "questionmark.circle.fill"
        case .sceneChanged:           "circle.dotted"
        case .posted, .notObserved:   "minus.circle"
        }
    }

    /// What the step history and the person are told, in the outcome's own
    /// words. It leads every summary, so no reader has to infer it.
    public var sentence: String {
        switch self {
        case .notObserved:            "nothing was posted"
        case .posted:                 "posted, nothing observed to change"
        case .sceneChanged:           "posted, the scene changed and the expected effect was not verified"
        case .expectedEffectVerified: "the expected effect was verified"
        case .interruptedAfterPost:   "posted, and the effect could not be established: do not repeat it"
        }
    }
}

extension ActOracle {

    /// The roles whose value accessibility answers for, so a `type` into one
    /// of them is checked against that value rather than against pixels.
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// The roles that carry their own on/off/mixed state.
    private static let statefulRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]

    /// Which oracle this action on this surface can be held to, and nil where
    /// this lab has none: a scroll, an arrow key, a chord whose effect lives
    /// somewhere nothing here can read. Such an action reaches `sceneChanged`
    /// and no higher, which is the Engine's two-scene rule and not a verdict.
    ///
    /// It is derived from the action and from the surface the Command was
    /// aimed at, never from the picture: the picture is what the oracle judges.
    static func of(_ action: SemanticAction, target: SceneObservation.Element?,
                   surface: WindowIdentity) -> ActOracle? {
        switch action {
        case .type(_, let text):
            guard let target, fieldRoles.contains(target.role ?? "") else { return nil }
            return .fieldReads(
                controlID  : target.id,
                bounds     : target.bounds,
                text       : text,
                beforeValue: target.value
            )
        case .click, .menu:
            if let target, statefulRoles.contains(target.role ?? "") {
                return .stateFlips(bounds: target.bounds, from: target.state)
            }
            return .surfaceCloses(windowNumber: surface.windowNumber)
        case .key(let name, let modifiers):
            // Escape on a surface means dismiss it; every other chord's effect
            // is somewhere this lab has no independent reading of.
            return name == .escape && modifiers.isEmpty
                ? .surfaceCloses(windowNumber: surface.windowNumber)
                : nil
        case .scroll:
            return nil
        }
    }
}

/// Before/after, as the Engine judges it, in this lab's own vocabulary.
///
/// The judgement is `ActVerification`'s: its oracle decides first, its
/// two-scene rule decides the rest. What is left here is the mapping onto
/// `ActionOutcome`, which is the shape the lab's reports and the Lab's views
/// read, plus the two measurements the Engine does not carry: the encoded
/// scene difference and the mean pixel delta.
enum OutcomeVerifier {

    /// What a Command the seat refused before its first event comes to. It is
    /// named here so that no caller can reach `posted` from a refusal.
    static let refusedBeforePost = VerificationResult(
        outcome: .notObserved, sceneChanged: false, effect: nil, pixelDifference: nil
    )

    static func verify(before: SceneSnapshot, beforeImage: CGImage,
                       after: SceneSnapshot, afterImage: CGImage, targetID: String?,
                       oracle: ActOracle?, surfaceIsGone: Bool) -> VerificationResult {
        let effect  = SceneDifference.effect(before: before, after: after, targetID: targetID)
        let verdict = ActVerification.verdict(before: before, after: after, effect: effect)
        let judged  = ActVerification.outcome(
            for     : verdict,
            label   : targetID ?? "the target",
            after   : after,
            oracle  : oracle,
            evidence: OracleEvidence(after: after, surfaceIsListed: !surfaceIsGone)
        )
        // Only an oracle verifies here. The Engine's two-scene rule may call a
        // structural change the gesture landing; this lab never promotes a
        // scene difference to a verification, so without an oracle the ceiling
        // is `sceneChanged`.
        let outcome: ActionOutcome = if oracle != nil, judged.isSuccess { .expectedEffectVerified }
            else if verdict == .ghost { .posted }
            else { .sceneChanged }
        return VerificationResult(outcome: outcome, sceneChanged: verdict != .ghost, effect: effect?.encoded,
                                  pixelDifference: FrameDifference.meanPixelDifference(beforeImage, afterImage))
    }

    /// What a Command that went out comes to when the reading that would
    /// settle it could not be taken. The surface's own identity still answers,
    /// so a dismissal whose after-frame was refused keeps its verified effect.
    static func interrupted(oracle: ActOracle?, surfaceIsGone: Bool) -> VerificationResult {
        let judged = ActVerification.interrupted(
            label   : "the target",
            oracle  : oracle,
            evidence: OracleEvidence(after: nil, surfaceIsListed: !surfaceIsGone)
        )
        return VerificationResult(
            outcome: judged.isSuccess ? .expectedEffectVerified : .interruptedAfterPost,
            sceneChanged: false, effect: nil, pixelDifference: nil
        )
    }
}

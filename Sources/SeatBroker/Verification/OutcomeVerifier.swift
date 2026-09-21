import CoreGraphics
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

    /// It went out and something moved that the predicate does not cover.
    /// It is a measurement, not a verification: OCR, a repaint, a caret.
    case sceneChanged

    /// The predicate derived from the action and the surface holds.
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

/// The proof one action on one surface can be held to.
///
/// It is derived from the action and from the surface the Command was aimed
/// at, never from the picture: the picture is what the predicate judges. Each
/// case names an oracle independent of the scene diff. A `type` is judged on
/// the field's own accessibility value, a stateful control on its
/// accessibility state, and the rest on whether the surface the Command was
/// aimed at still exists.
///
/// `unqualified` is the honest answer where this lab has no independent
/// oracle: a scroll, an arrow key, a chord whose effect lives somewhere the
/// lab cannot read. Such an action reaches `sceneChanged` and no higher.
enum ExpectedEffect: Sendable, Equatable {

    /// The surface the Command was aimed at is gone, read from the window
    /// server by identity. It is the proof of a dismissal, and for a plain
    /// click on a control with no state of its own it is the only semantic
    /// proof available here: a click that legitimately does something else
    /// reads as `sceneChanged`, which is a measurement and not a failure.
    case surfaceCloses(windowNumber: Int)

    /// The field at these bounds reads this text. Accessibility supplies the
    /// value, so this never falls back to OCR where a value exists.
    case fieldReads(controlID: String, bounds: CGRect, text: String, beforeValue: String?)

    /// The control at these bounds no longer reads the state it had.
    case stateFlips(bounds: CGRect, from: String?)

    /// No oracle this lab can hold the action to.
    case unqualified

    /// The roles whose value accessibility answers for, so a `type` into one
    /// of them is checked against that value rather than against pixels.
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// The roles that carry their own on/off/mixed state.
    private static let statefulRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]

    static func of(_ action: SemanticAction, target: SceneObservation.Element?,
                   surface: WindowIdentity) -> ExpectedEffect {
        switch action {
        case .type(_, let text):
            guard let target, fieldRoles.contains(target.role ?? "") else { return .unqualified }
            return .fieldReads(
                controlID : target.id,
                bounds    : target.bounds,
                text      : text,
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
                : .unqualified
        case .scroll:
            return .unqualified
        }
    }
}

/// Before/after: the predicate the action is held to, the Perception layer's
/// scene difference, the scene token, and a mean pixel delta.
enum OutcomeVerifier {

    /// What a Command the seat refused before its first event comes to. It is
    /// named here so that no caller can reach `posted` from a refusal.
    static let refusedBeforePost = VerificationResult(
        outcome: .notObserved, sceneChanged: false, effect: nil, pixelDifference: nil
    )

    static func verify(before: SceneSnapshot, beforeImage: CGImage,
                       after: SceneSnapshot, afterImage: CGImage, targetID: String?,
                       expected: ExpectedEffect, afterElements: [SceneObservation.Element],
                       surfaceIsGone: Bool) -> VerificationResult {
        let effect = SceneDifference.effect(before: before, after: after, targetID: targetID)
        let changed = effect != nil || before.token != after.token
        let outcome: ActionOutcome = if holds(expected, in: afterElements, surfaceIsGone: surfaceIsGone) {
            .expectedEffectVerified
        } else if changed {
            .sceneChanged
        } else {
            .posted
        }
        return VerificationResult(outcome: outcome, sceneChanged: changed, effect: effect?.encoded,
                                  pixelDifference: FrameDifference.meanPixelDifference(beforeImage, afterImage))
    }

    /// What a Command that went out comes to when the reading that would
    /// settle it could not be taken.
    ///
    /// The surface's own identity is still asked, and that is the whole point
    /// of asking it apart from the picture: a Cancel that closed its panel
    /// stays a Cancel that closed its panel while the person's focus is still
    /// coming back, and the run neither loses the effect nor clicks again.
    static func interrupted(expected: ExpectedEffect, surfaceIsGone: Bool) -> VerificationResult {
        VerificationResult(
            outcome: holds(expected, in: nil, surfaceIsGone: surfaceIsGone)
                ? .expectedEffectVerified : .interruptedAfterPost,
            sceneChanged: false, effect: nil, pixelDifference: nil
        )
    }

    /// Whether the predicate holds. `after` is nil when no scene could be
    /// perceived, which leaves the closure oracle the only one answering.
    static func holds(_ expected: ExpectedEffect, in after: [SceneObservation.Element]?,
                      surfaceIsGone: Bool) -> Bool {
        switch expected {
        case .surfaceCloses:
            surfaceIsGone
        case .fieldReads(let controlID, let bounds, let text, let beforeValue):
            after?.contains {
                $0.id == controlID
                    && covers($0, bounds)
                    && typedValueTransition(
                        before: beforeValue,
                        after : $0.value,
                        typed : text
                    )
            } ?? false
        case .stateFlips(let bounds, let from):
            after?.contains { covers($0, bounds) && $0.state != nil && $0.state != from } ?? false
        case .unqualified:
            false
        }
    }

    /// Whether an element of the after-scene is the one that was acted on.
    ///
    /// It is matched by the stable AX control identity and place. Bounds are normalized to the
    /// frame, and either centre inside the other rectangle is the match, so a
    /// control that grew a focus ring is still the same control. Only an
    /// accessibility-backed element answers: rule 2 makes AX the oracle where
    /// one exists, and an OCR guess at a field's contents is not one.
    private static func covers(_ element: SceneObservation.Element, _ bounds: CGRect) -> Bool {
        element.role?.hasPrefix("AX") == true
            && (bounds.contains(CGPoint(x: element.bounds.midX, y: element.bounds.midY))
                || element.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
    }

    /// Text input currently clicks then inserts. Without an independently
    /// observed selection range, a click can put the caret anywhere. The only
    /// positive oracle is an exact contiguous insertion into the observed old
    /// value; it preserves raw spaces and line breaks and cannot pass because
    /// the field already contained the requested substring.
    private static func typedValueTransition(before: String?, after: String?, typed: String) -> Bool {
        guard let before, let after, !typed.isEmpty else { return false }
        guard after != before else { return false }
        var split = before.startIndex
        while true {
            let candidate = String(before[..<split]) + typed + String(before[split...])
            if after == candidate { return true }
            guard split < before.endIndex else { return false }
            split = before.index(after: split)
        }
    }
}

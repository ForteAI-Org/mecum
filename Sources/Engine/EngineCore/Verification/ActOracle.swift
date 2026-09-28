//
//  ActOracle.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import PerceptionCore

/// ActOracle is the proof of one gesture that does not come from the difference between two scenes.
///
/// The verification rule is blind on purpose: a window that changed is not the gesture landing, and
/// a window that did not change is not proof it failed. An oracle is the second reading that settles
/// those two cases, taken where the application answers for itself rather than in the picture: the
/// window server's own list, and the accessibility value or state of the control that was acted on.
/// It is consulted before the scene difference and it never softens it. An oracle that does not hold
/// leaves an honest miss, with the reading that contradicted it said out loud.
///
/// An action with no oracle is `nil`, never a fourth case: that is the ordinary two-scene rule, and
/// it stays exactly what it was.
public enum ActOracle: Sendable, Equatable {

    /// The surface the gesture was aimed at is gone from the window server's list, by identity. It
    /// is the proof of a dismissal, and the only semantic proof a click on a stateless control has.
    case surfaceCloses(windowNumber: Int)

    /// The field at these bounds reads the value it had with the typed text inserted into it.
    /// Accessibility supplies the value, so this never falls back to recognized pixels.
    case fieldReads(controlID: String, bounds: CGRect, text: String, beforeValue: String?)

    /// The control at these bounds no longer shows the state it had.
    case stateFlips(bounds: CGRect, from: String?)

    /// Whether the reading the oracle asks for came back the way it was promised.
    public func holds(given evidence: OracleEvidence) -> Bool {
        switch self {
            case .surfaceCloses:
                return !evidence.surfaceIsListed

            case .fieldReads(let controlID, let bounds, let text, let beforeValue):
                return evidence.after?.elements.contains {
                    $0.id == controlID
                        && Self.covers($0, bounds)
                        && Self.typedValueTransition(before: beforeValue, after: $0.value, typed: text)
                } ?? false

            case .stateFlips(let bounds, let from):
                return evidence.after?.elements.contains {
                    Self.covers($0, bounds) && $0.state != nil && $0.state?.rawValue != from
                } ?? false
        }
    }

    /// What the sentence says when this oracle is what decided the outcome.
    public var confirmation: String {
        switch self {
            case .surfaceCloses(let windowNumber):
                "the window server no longer lists window \(windowNumber): the surface it was aimed at closed"
            case .fieldReads:
                "the field's accessibility value reads the text that was typed into it"
            case .stateFlips(_, let from):
                "the control's accessibility state no longer reads '\(from ?? "unknown")'"
        }
    }

    /// What the sentence says when the reading came back and contradicted the oracle.
    public var contradiction: String {
        switch self {
            case .surfaceCloses(let windowNumber):
                "the window server still lists window \(windowNumber)"
            case .fieldReads:
                "the field's accessibility value does not read the text that was typed into it"
            case .stateFlips(_, let from):
                "the control's accessibility state still reads '\(from ?? "unknown")'"
        }
    }

    /// Whether an element of the after-scene is the one that was acted on.
    ///
    /// It is matched by place, with either centre inside the other rectangle, so a control that grew
    /// a focus ring is still the same control. Only an accessibility-backed element answers: the
    /// oracle is accessibility where one exists, and a recognized guess at a field's contents is not
    /// one.
    private static func covers(_ element: SceneElement, _ bounds: CGRect) -> Bool {
        element.role?.hasPrefix("AX") == true
            && (bounds.contains(element.bounds.center)
                || element.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
    }

    /// Text input clicks and then inserts. Without an independently observed selection range a click
    /// can put the caret anywhere, so the only positive oracle is an exact contiguous insertion into
    /// the observed old value: it keeps raw spaces and line breaks, and it cannot pass because the
    /// field already contained the requested substring.
    private static func typedValueTransition(before: String?, after: String?, typed: String) -> Bool {
        guard let before, let after, !typed.isEmpty else { return false }
        guard after != before else { return false }
        var split = before.startIndex
        while true {
            if after == String(before[..<split]) + typed + String(before[split...]) { return true }
            guard split < before.endIndex else { return false }
            split = before.index(after: split)
        }
    }
}

/// OracleEvidence is what a composition root read for an oracle, and nothing it inferred.
///
/// There is no role protocol beside it on purpose. Two of the three readings are already in the
/// scene the verification is handed: `SceneAugmenting` puts the live accessibility role, value and
/// state on every element, so asking a second time would ask the same tree twice. The third, whether
/// the surface is still listed, is `WindowListing`'s answer in the foreground and the seat's
/// `surfaceIsGone` on the seat, both of which exist. A protocol with one implementation and no
/// second one in sight does not get written.
public struct OracleEvidence: Sendable, Equatable {

    /// The scene perceived after the gesture, and nil when none could be taken: a reading that was
    /// refused leaves the closure oracle the only one that can answer.
    public let after: SceneSnapshot?

    /// Whether the window server still lists the surface the gesture was aimed at.
    public let surfaceIsListed: Bool

    public init(after: SceneSnapshot?, surfaceIsListed: Bool) {
        self.after           = after
        self.surfaceIsListed = surfaceIsListed
    }
}

extension ActVerification {

    /// The outcome of a gesture that has an oracle, consulted before the scene difference.
    ///
    /// An oracle that holds is the whole answer: `found_acted`, with the sentence saying which
    /// reading decided it, however little else moved. An oracle that does not hold leaves the honest
    /// miss and adds the reading that contradicted it, including where the scene difference alone
    /// would have called the gesture landed: a structural change the oracle does not cover is a
    /// measurement, not the proof this gesture was for. With no oracle this is the two-scene rule,
    /// unchanged.
    ///
    /// The miss is `acted_unverified` and not `honest_miss`, which says the target was never on this
    /// screen: the gesture did go out, so that kind would be a different and false statement.
    public static func outcome(
        for verdict: Verdict,
        label      : String,
        after      : SceneSnapshot?,
        oracle     : ActOracle?,
        evidence   : OracleEvidence
    ) -> ActOutcome {
        guard let oracle else { return outcome(for: verdict, label: label, after: after) }
        if oracle.holds(given: evidence) {
            return ActOutcome(.foundActed, "acted on '\(label)': \(oracle.confirmation)", scene: after)
        }
        let honest = outcome(for: verdict, label: label, after: after)
        let message = honest.kind == .foundActed
            ? "\(honest.message), but \(oracle.contradiction); re-perceive and re-decide"
            : "\(honest.message); \(oracle.contradiction)"
        return ActOutcome(.actedUnverified, message, scene: after)
    }

    /// The outcome of a gesture that went out and whose after-scene could not be read.
    ///
    /// The surface's own identity is still asked, and that is the point of asking it apart from the
    /// picture: a Cancel that closed its panel stays a Cancel that closed its panel while the focus
    /// is still coming back, and the caller neither loses the effect nor clicks again. Anything else
    /// is uncertain, which is not a failure and is never a reason to repeat the gesture.
    public static func interrupted(label: String, oracle: ActOracle?, evidence: OracleEvidence) -> ActOutcome {
        if let oracle, oracle.holds(given: evidence) {
            return ActOutcome(.foundActed, "acted on '\(label)': \(oracle.confirmation)")
        }
        return ActOutcome(
            .actedUnverified,
            "acted on '\(label)': the scene after it could not be read, so its effect could not be "
                + "established: re-perceive, do not repeat it"
        )
    }
}

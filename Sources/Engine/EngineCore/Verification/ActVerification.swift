//
//  ActVerification.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import PerceptionCore

/// ActVerification decides whether a gesture landed, from the scenes before and after it.
///
/// Success requires a structural effect: an element appeared, vanished, flipped, or the title
/// changed. Identical tokens mean the window did not change at all. A token that differs with no
/// attributable effect is animation or repaint, not the action landing; calling that success let a
/// model burn rounds on a click that never happened.
public enum ActVerification {

    /// What the two scenes say about the gesture.
    public enum Verdict: Sendable, Equatable {
        /// A structural effect was observed. When an expectation was given and its family differs,
        /// `matchesExpectation` is false and the caller reports the surprise.
        case landed(SceneEffect, matchesExpectation: Bool)
        /// The scene is byte-identical: the window did not change.
        case ghost
        /// Pixels changed, nothing structural did: likely repaint, not the action.
        case unattributable
    }

    /// Judges an action. `targetID` enables the state-flip reading; `expected` is a learned effect
    /// to compare families against, when memory has one.
    public static func verdict(
        before  : SceneSnapshot,
        after   : SceneSnapshot,
        targetID: String?,
        expected: SceneEffect? = nil
    ) -> Verdict {
        if after.token == before.token { return .ghost }
        guard let effect = SceneDifference.effect(before: before, after: after, targetID: targetID) else {
            return .unattributable
        }
        let matches = expected.map { $0.family == effect.family } ?? true
        return .landed(effect, matchesExpectation: matches)
    }

    /// The outcome a verdict earns, with the sentence a model needs next.
    public static func outcome(for verdict: Verdict, label: String, after: SceneSnapshot?) -> ActOutcome {
        switch verdict {
            case .landed(let effect, true):
                return ActOutcome(.foundActed, "clicked '\(label)' — \(effect.summary)", scene: after)
            case .landed(let effect, false):
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)' — observed \(effect.summary), not the expected effect; "
                        + "re-perceive and re-decide",
                    scene: after
                )
            case .ghost:
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)' — this window did NOT change (identical scene)",
                    scene: after
                )
            case .unattributable:
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)' — the window's pixels changed but nothing structural did; "
                        + "likely a repaint, not the action landing",
                    scene: after
                )
        }
    }
}

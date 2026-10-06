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
/// changed, or a known native text selection changed. Identical tokens mean the window did not
/// change at all. A token that differs with no attributable effect leaves the result unverified:
/// content may have changed, or a repaint may
/// have occurred. That uncertainty proves neither successful delivery nor absence of an effect.
public enum ActVerification {

    /// What the two scenes say about the gesture.
    public enum Verdict: Sendable, Equatable {
        /// A structural effect was observed. When an expectation was given and its family differs,
        /// `matchesExpectation` is false and the caller reports the surprise.
        case landed(SceneEffect, matchesExpectation: Bool)
        /// The scene is byte-identical: the window did not change.
        case ghost
        /// Pixels changed without a classified structural effect; the result remains unverified.
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
        verdict(
            before  : before,
            after   : after,
            effect  : SceneDifference.effect(before: before, after: after, targetID: targetID),
            expected: expected
        )
    }

    /// Judges an action from an effect the caller already named, for a caller that adjusted the
    /// scene difference with facts the scenes alone do not hold (whether a pop-up window is open).
    public static func verdict(
        before  : SceneSnapshot,
        after   : SceneSnapshot,
        effect  : SceneEffect?,
        expected: SceneEffect? = nil
    ) -> Verdict {
        if after.token == before.token { return .ghost }
        guard let effect else { return .unattributable }
        let matches = expected.map { $0.family == effect.family } ?? true
        return .landed(effect, matchesExpectation: matches)
    }

    /// The outcome a verdict earns, with the sentence a model needs next.
    public static func outcome(for verdict: Verdict, label: String, after: SceneSnapshot?) -> ActOutcome {
        switch verdict {
            case .landed(let effect, true):
                return ActOutcome(.foundActed, "clicked '\(label)': \(effect.summary)", scene: after)
            case .landed(let effect, false):
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)': observed \(effect.summary), not the expected effect; "
                        + "re-perceive and re-decide",
                    scene: after
                )
            case .ghost:
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)': this window did NOT change (identical scene)",
                    scene: after
                )
            case .unattributable:
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)': the window's pixels changed but nothing structural did; "
                        + "verify the intended result before deciding on further input",
                    scene: after
                )
        }
    }
}

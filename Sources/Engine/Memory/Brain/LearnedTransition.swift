//
//  LearnedTransition.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// LearnedTransition is a causal edge learned by diffing scenes across an input event: this anchor,
/// under this trigger, produced this effect. A state effect is trusted only at evidence two or more;
/// a menu reveal is trusted from its first sighting, because the menu was watched appearing.
public struct LearnedTransition: Sendable, Equatable, Codable {

    public var anchorKey: String
    public var trigger: TransitionTrigger
    /// The effect's stable encoding (`SceneEffect.encoded`).
    public var effect: String
    public var evidence: Int
    public var lastObserved: Date
    public var lastObservedEpoch: Int?

    public init(
        anchorKey        : String,
        trigger          : TransitionTrigger,
        effect           : String,
        evidence         : Int = 1,
        lastObserved     : Date,
        lastObservedEpoch: Int? = nil
    ) {
        self.anchorKey         = anchorKey
        self.trigger           = trigger
        self.effect            = effect
        self.evidence          = evidence
        self.lastObserved      = lastObserved
        self.lastObservedEpoch = lastObservedEpoch
    }

    /// Key is the triple `BrainUpdater.recordTransition` accumulates evidence under: one anchor,
    /// one trigger, one effect string. It names a transition inside a brain, where no other
    /// identity exists; a stored projection keeps its own row id beside it.
    public struct Key: Sendable, Equatable, Hashable {

        public let anchorKey: String
        public let trigger: TransitionTrigger
        public let effect: String

        public init(anchorKey: String, trigger: TransitionTrigger, effect: String) {
            self.anchorKey = anchorKey
            self.trigger   = trigger
            self.effect    = effect
        }
    }

    /// The triple this transition accumulates evidence under.
    public var key: Key { Key(anchorKey: anchorKey, trigger: trigger, effect: effect) }

    /// True for a menu reveal, the one effect trusted at evidence one.
    public var isMenuReveal: Bool { effect.hasPrefix("menuOpened:") }

    /// True when consumers may act on this edge.
    public var isTrusted: Bool { evidence >= 2 || isMenuReveal }

    /// The decoded effect, when the encoding is one the scene vocabulary knows.
    public var sceneEffect: SceneEffect? { SceneEffect(encoded: effect) }

    /// A compact human rendering of the effect.
    public var summary: String { sceneEffect?.summary ?? effect }
}

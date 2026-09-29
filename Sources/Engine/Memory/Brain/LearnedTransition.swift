//
//  LearnedTransition.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// LearnedTransition is a causal edge learned by diffing scenes across an input event: this anchor,
/// under this trigger, produced this effect. A state effect is trusted only at evidence two or more;
/// a menu reveal is trusted from its first sighting, because the menu was watched appearing.
///
/// `verb` is the action that produced the edge. A transition stored before verbs were kept has
/// none: its `click` trigger may have come from a click, a double-click or a `set_toggle`, which can
/// do different things, so it is kept and shown as history but is never evidence of any one verb.
/// Its `rightclick` trigger had one producer, the right-click, and stays that verb's. The trigger is
/// still written, so a build that predates `verb` reads the file as before.
public struct LearnedTransition: Sendable, Equatable, Codable {

    public var anchorKey: String
    public var trigger: TransitionTrigger
    /// The verb that produced the edge; nil for an edge stored before verbs were kept.
    public var verb: ActionVerb?
    /// The effect's stable encoding (`SceneEffect.encoded`).
    public var effect: String
    public var evidence: Int
    public var lastObserved: Date
    public var lastObservedEpoch: Int?

    public init(
        anchorKey        : String,
        trigger          : TransitionTrigger,
        verb             : ActionVerb? = nil,
        effect           : String,
        evidence         : Int = 1,
        lastObserved     : Date,
        lastObservedEpoch: Int? = nil
    ) {
        self.anchorKey         = anchorKey
        self.trigger           = trigger
        self.verb              = verb
        self.effect            = effect
        self.evidence          = evidence
        self.lastObserved      = lastObserved
        self.lastObservedEpoch = lastObservedEpoch
    }

    /// The verb this edge is evidence of: its own, a stored right-click's, or nil for a stored click
    /// whose verb cannot be told.
    public var attributedVerb: ActionVerb? {
        verb ?? (trigger == .rightClick ? .rightClick : nil)
    }

    /// The edge's producer for a person: the verb, or the stored trigger marked as of unknown verb.
    public var producer: String {
        attributedVerb?.rawValue ?? (trigger == .click ? "click (verb unknown)" : trigger.rawValue)
    }

    /// True for a menu reveal, the one effect trusted at evidence one.
    public var isMenuReveal: Bool { effect.hasPrefix("menuOpened:") }

    /// True when consumers may act on this edge.
    public var isTrusted: Bool { evidence >= 2 || isMenuReveal }

    /// The decoded effect, when the encoding is one the scene vocabulary knows.
    public var sceneEffect: SceneEffect? { SceneEffect(encoded: effect) }

    /// A compact human rendering of the effect.
    public var summary: String { sceneEffect?.summary ?? effect }
}

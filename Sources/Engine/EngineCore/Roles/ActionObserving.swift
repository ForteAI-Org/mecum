//
//  ActionObserving.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// ActionRecord is what one performed action taught: the element, the verb, and the effect the
/// scenes attributed to it, or none. Memory turns records into evidence; the engine only writes them.
public struct ActionRecord: Sendable, Equatable {

    public let bundleID: String
    public let element: SceneElement
    public let verb: ActionVerb
    public let effect: SceneEffect?
    public let windowTitleAfter: String?

    public init(
        bundleID        : String,
        element         : SceneElement,
        verb            : ActionVerb,
        effect          : SceneEffect?,
        windowTitleAfter: String?
    ) {
        self.bundleID         = bundleID
        self.element          = element
        self.verb             = verb
        self.effect           = effect
        self.windowTitleAfter = windowTitleAfter
    }
}

/// ActionObserving receives every performed action's record, after the outcome is decided. A
/// conformer must not fail the action: it records or it drops, and it says nothing back.
public protocol ActionObserving: Sendable {

    func record(_ record: ActionRecord) async
}

/// EffectExpecting answers what a verb on an element is expected to do, from trusted memory, or nil
/// when memory has no opinion. The engine compares by effect family, never by exact string.
public protocol EffectExpecting: Sendable {

    func expectedEffect(of verb: ActionVerb, on element: SceneElement, in bundleID: String) async -> SceneEffect?
}

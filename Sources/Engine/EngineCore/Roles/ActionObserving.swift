//
//  ActionObserving.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// ActionAttempt says how far an action or an input got: its gesture went out, it was never sent (a
/// dry run, a refusal, a target that named no element, a toggle already in its state, a menu item
/// that was not there), or the actuator failed to deliver it. What follows a failed or absent
/// delivery is unknown, never an effect.
public enum ActionAttempt: Sendable, Equatable {
    case delivered
    case notAttempted(reason: String)
    case deliveryFailed(String)
}

/// ActionRecord is what one performed action taught: the element, the verb, and the effect the
/// scenes attributed to it, or none. Memory turns records into evidence; the engine only writes them.
public struct ActionRecord: Sendable, Equatable {

    public let bundleID: String
    public let element: SceneElement
    public let verb: ActionVerb
    public let effect: SceneEffect?
    public let windowTitleAfter: String?
    public let before: PerceivedWindow?
    public let after: PerceivedWindow?
    public let attempt: ActionAttempt

    public init(
        bundleID        : String,
        element         : SceneElement,
        verb            : ActionVerb,
        effect          : SceneEffect?,
        windowTitleAfter: String?,
        before          : PerceivedWindow? = nil,
        after           : PerceivedWindow? = nil,
        attempt         : ActionAttempt = .delivered
    ) {
        self.bundleID         = bundleID
        self.element          = element
        self.verb             = verb
        self.effect           = effect
        self.windowTitleAfter = windowTitleAfter
        self.before           = before
        self.after            = after
        self.attempt          = attempt
    }
}

/// InputRecord is what one input (typing, a key, a scroll, a drag, a contextual menu choice) saw and
/// did: the input as requested, the element it resolved (nil when none did), the perception used
/// before the gesture (nil when no scene could be read), the menu it read when it opened one, the
/// perception after it, the effect the scenes attributed to it and how far the gesture got. An
/// input teaches the brain nothing today; the record is a fact for the living memory.
public struct InputRecord: Sendable, Equatable {

    public let bundleID: String
    public let input: InputRequest.Input
    public let target: SceneElement?
    public let before: PerceivedWindow?
    public let menu: PerceivedWindow?
    public let after: PerceivedWindow?
    public let effect: SceneEffect?
    public let attempt: ActionAttempt

    public init(
        bundleID: String,
        input   : InputRequest.Input,
        target  : SceneElement?,
        before  : PerceivedWindow?,
        menu    : PerceivedWindow? = nil,
        after   : PerceivedWindow? = nil,
        effect  : SceneEffect? = nil,
        attempt : ActionAttempt = .delivered
    ) {
        self.bundleID = bundleID
        self.input    = input
        self.target   = target
        self.before   = before
        self.menu     = menu
        self.after    = after
        self.effect   = effect
        self.attempt  = attempt
    }
}

/// ActionObserving receives every action's and every input's record, after the outcome is decided. A
/// conformer must not fail the action: it records or it drops, and it says nothing back. An input's
/// record has a default that drops it, so an observer that learns only from actions compiles as it did.
public protocol ActionObserving: Sendable {

    func record(_ record: ActionRecord) async

    func record(_ input: InputRecord) async
}

public extension ActionObserving {

    func record(_ input: InputRecord) async {}
}

/// EffectExpecting answers what a verb on an element is expected to do, from trusted memory, or nil
/// when memory has no opinion. The engine compares by effect family, never by exact string.
public protocol EffectExpecting: Sendable {

    func expectedEffect(of verb: ActionVerb, on element: SceneElement, in bundleID: String) async -> SceneEffect?
}

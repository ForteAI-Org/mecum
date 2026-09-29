//
//  ActionArguments.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import PerceptionCore

/// ActionArguments is what an `ActionRequest` asks for in semantic terms: the target as the caller
/// named it, the verb, the panel that narrows it, and the state a `setToggle` must reach. It is the
/// part of a request a turn's history may keep: it has no process, application, window or
/// coordinate, and no dry-run flag.
public struct ActionArguments: Sendable, Hashable {

    /// The element id or label the caller named, before resolution.
    public let target: String
    public let verb: ActionVerb
    public let section: String?
    /// The requested state of a `setToggle`; nil for other verbs or when the caller gave none.
    public let desiredState: ControlState?

    public init(target: String, verb: ActionVerb, section: String? = nil, desiredState: ControlState? = nil) {
        self.target       = target
        self.verb         = verb
        self.section      = section
        self.desiredState = desiredState
    }
}

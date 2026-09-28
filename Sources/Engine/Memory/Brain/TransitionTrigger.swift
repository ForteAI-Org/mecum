//
//  TransitionTrigger.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore

/// TransitionTrigger is the input a learned transition was observed after.
public enum TransitionTrigger: String, Sendable, Codable {

    case hover
    case click
    case rightClick = "rightclick"

    /// The trigger an action verb produces; a toggle set is a click.
    public init(_ verb: ActionVerb) {
        switch verb {
            case .click, .doubleClick, .tripleClick, .setToggle: self = .click
            case .rightClick                                   : self = .rightClick
        }
    }
}

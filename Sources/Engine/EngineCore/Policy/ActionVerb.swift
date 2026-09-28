//
//  ActionVerb.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// ActionVerb is the closed set of gestures the engine performs unattended. Anything outside it is a
/// person's job or a later phase; a model cannot name a verb that is not here.
///
/// The raw values are the tool vocabulary the previous engine spoke.
public enum ActionVerb: String, Sendable, Codable, CaseIterable {

    case click
    case doubleClick = "double_click"
    /// Three presses as one train: selects a line or a paragraph of text.
    case tripleClick = "triple_click"
    case rightClick  = "right_click"
    /// Reach a desired state on a stateful control, idempotently: no click when already there.
    case setToggle   = "set_toggle"

    /// The past tense a report opens with.
    public var performed: String {
        switch self {
            case .click      : "clicked"
            case .doubleClick: "double-clicked"
            case .tripleClick: "triple-clicked"
            case .rightClick : "right-clicked"
            case .setToggle  : "set"
        }
    }
}

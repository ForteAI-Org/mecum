//
//  ControlState.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

/// ControlState is the read state of a stateful control: a switch, a checkbox, a radio button.
/// `mixed` is a checkbox standing for a group that disagrees. `unknown` is a control known to carry
/// state whose value could not be read this frame; it is not the absence of state, which a scene
/// element expresses with `nil`.
public enum ControlState: String, Sendable, Codable, CaseIterable {

    case on
    case off
    case mixed
    case unknown

    /// The opposite of a definite state; `mixed` and `unknown` have none and flip to themselves.
    public var toggled: ControlState {
        switch self {
            case .on     : .off
            case .off    : .on
            case .mixed  : .mixed
            case .unknown: .unknown
        }
    }
}

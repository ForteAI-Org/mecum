//
//  TargetOperability.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// TargetOperability is the answer to "may the agent act on the target now", and
/// it is one of two things rather than a score.
///
/// `operational` means the selected window is the same attested window, the
/// assignment's containment is verified, the observation offered is of this
/// selection at its current geometry, and no other cause of suspension is open.
/// It is still not permission: the Facility gate, the Cursor Fence and the
/// checks taken where input is admitted are not in this value, and a Command is
/// re-verified against its observation at admission whatever this said a moment
/// earlier.
///
/// `suspended` carries the target it is suspended on, which is often not nil:
/// keeping the selection while the input waits is the whole difference between
/// a Selected Target and an Operational Target.
nonisolated package enum TargetOperability: Sendable, Equatable {

    case operational(SelectedTarget)

    case suspended(target: SelectedTarget?, causes: [SelectionSuspension])

    package var isOperational: Bool {
        if case .operational = self { return true }
        return false
    }

    /// The selected target, operational or not.
    package var target: SelectedTarget? {
        switch self {
            case .operational(let target):   target
            case .suspended(let target, _):  target
        }
    }

    /// Every open cause, empty when the target is operational.
    package var causes: [SelectionSuspension] {
        switch self {
            case .operational:            []
            case .suspended(_, let causes): causes
        }
    }
}

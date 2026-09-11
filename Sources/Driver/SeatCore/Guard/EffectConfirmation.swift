//
//  EffectConfirmation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// EffectConfirmation is the consumer's answer to "did the input do anything".
/// The kit never decides it: verifying an effect needs the observation layer
/// the kit deliberately does not have. Three values, because the difference
/// between "nothing happened" and "I do not know" is the difference between a
/// safe resend and a duplicated action.
public enum EffectConfirmation: String, Sendable, Equatable {

    /// The effect was seen. The story is closed: whoever acts next starts from
    /// a fresh observation.
    case observed

    /// It was verified that nothing happened. The Command may be sent again.
    case absent

    /// Not established. The Command is never repeated, and a recoverable Issue
    /// arriving on top of it fails the seat with `ambiguousEffect`. A Command
    /// that is never confirmed stays here: there is no timeout that promotes it.
    case unknown
}

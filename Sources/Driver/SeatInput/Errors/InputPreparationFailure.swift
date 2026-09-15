//
//  InputPreparationFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import SeatCore

/// InputPreparationFailure is a refusal while a Preparation was being applied
/// or held, before a Command Receipt exists. `cause` remains the original typed
/// refusal and `cleanupCause` remains the original typed restore failure, so a
/// consumer never has to recover either one from prose.
nonisolated public struct InputPreparationFailure: Error, Sendable {

    public let progress: InputProgress
    public let cause: any Error
    public let cleanupCause: (any Error)?

    public init(
        progress    : InputProgress,
        cause       : any Error,
        cleanupCause: (any Error)?
    ) {
        self.progress     = progress
        self.cause        = cause
        self.cleanupCause = cleanupCause
    }
}

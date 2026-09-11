//
//  InputProgress.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// PreparationStep names one record in the Preparation, in posting order.
/// A failed step is separate from a completed one because a nonzero return
/// from the window server does not prove that the attempted record had no
/// effect.
public enum PreparationStep: String, Sendable, Equatable, CaseIterable {

    /// The 0x0D record that makes the target consider itself active.
    case activation

    /// The first key-window record, type 0x01.
    case keyWindowFirst

    /// The second key-window record, type 0x02.
    case keyWindowSecond

    /// The 0x0D record that gives the target back its inactive state.
    case restore
}

/// InputProgress is the durable account of a Preparation that did not reach
/// its normal return point. It says what completed, where execution stopped,
/// whether the failed post may still have changed state, and what recovery is
/// still required after cleanup.
public struct InputProgress: Sendable, Equatable {

    /// Recovery is the state-changing work still required after the reported
    /// cleanup. A consumer can surface or schedule it, but must not infer that
    /// the Command itself is safe to replay.
    public enum Recovery: String, Sendable, Equatable {
        case restorePreparation
    }

    /// Preparation records that returned success, in posting order.
    public let completedSteps: [PreparationStep]

    /// The record being executed when the primary failure occurred. Nil means
    /// the Preparation completed and the primary failure happened afterwards.
    public let failedStep: PreparationStep?

    /// True when the failed step reached the window server and its nonzero
    /// return leaves the resulting state uncertain.
    public let failedStepMayHaveTakenEffect: Bool

    /// What happened when the facility tried to undo the partial Preparation.
    public let cleanup: InputCleanupResult

    /// Work still required after cleanup. Nil means cleanup either succeeded
    /// or no state-changing record was attempted.
    public var neededRecovery: Recovery? {
        cleanup.needsRecovery ? .restorePreparation : nil
    }

    public init(
        completedSteps              : [PreparationStep],
        failedStep                  : PreparationStep?,
        failedStepMayHaveTakenEffect: Bool,
        cleanup                     : InputCleanupResult
    ) {
        self.completedSteps               = completedSteps
        self.failedStep                   = failedStep
        self.failedStepMayHaveTakenEffect = failedStepMayHaveTakenEffect
        self.cleanup                      = cleanup
    }
}

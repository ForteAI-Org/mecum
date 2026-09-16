//
//  InputCleanupResult.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// InputCleanupResult reports the bounded attempt to undo a Preparation.
/// `failed` carries the original refusal code when the window server supplied
/// one. Nil means cleanup failed before such a code existed.
public enum InputCleanupResult: Sendable, Equatable {

    /// No state-changing Preparation record succeeded or had uncertain effect.
    case notRequired

    /// Cleanup was required but could not be attempted.
    case notAttempted

    /// The restore record returned success.
    case succeeded

    /// The restore failed. A nonnil code is the unmodified window server code.
    case failed(code: Int32?)

    /// True when the target may still hold the Preparation state.
    public var needsRecovery: Bool {
        switch self {
            case .notRequired, .succeeded: false
            case .notAttempted, .failed  : true
        }
    }
}


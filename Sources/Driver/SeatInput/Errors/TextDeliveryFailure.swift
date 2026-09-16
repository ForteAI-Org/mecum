//
//  TextDeliveryFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import SeatCore

/// TextDeliveryFailure is a bulk delivery that stopped partway, and it carries
/// the outcome rather than only the cause.
///
/// It exists for the same reason `InputSequenceFailure` does: the chunks that
/// already went out **are already inside the target**, and an error that says
/// only "it failed" invites the caller to start again from the beginning and
/// type the first half twice. The outcome says exactly how much is in there.
nonisolated public struct TextDeliveryFailure: Error, Sendable {

    /// What was delivered before it stopped. Its `commit` is always
    /// `.stoppedAfter`.
    public let outcome: TextDeliveryOutcome

    /// Why it stopped, unchanged. A refusal of the driver, a cancellation, or a
    /// recipient that is no longer the window the delivery started against.
    public let cause: any Error

    public init(outcome: TextDeliveryOutcome, cause: any Error) {
        self.outcome = outcome
        self.cause   = cause
    }
}

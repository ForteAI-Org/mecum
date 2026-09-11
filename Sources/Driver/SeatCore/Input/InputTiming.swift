//
//  InputTiming.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// InputTiming is how long one send took, split into the parts the kit controls
/// and the waits imposed by the target transaction. The Preparation settle and
/// process exclusion are kept apart so neither can be mistaken for posting cost.
public struct InputTiming: Sendable, Equatable {

    /// Wall time of the posting loop, including a Platform's intentional drag
    /// pacing and excluding event construction, routing and settle.
    public let postingNanoseconds: UInt64

    /// Wall time spent waiting for the target to apply the preparation.
    public let settleNanoseconds: UInt64

    /// Wall time spent behind another transaction for the same target PID.
    ///
    /// This is zero for an uncontended acquisition. In a sequence only the first
    /// Receipt carries the wait paid by the whole sequence, so totals do not
    /// count one wait once per Command.
    public let exclusionWaitingNanoseconds: UInt64

    public init(
        postingNanoseconds         : UInt64,
        settleNanoseconds          : UInt64 = 0,
        exclusionWaitingNanoseconds: UInt64 = 0
    ) {
        self.postingNanoseconds         = postingNanoseconds
        self.settleNanoseconds          = settleNanoseconds
        self.exclusionWaitingNanoseconds = exclusionWaitingNanoseconds
    }
}

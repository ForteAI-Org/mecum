//
//  SeatInterruption.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// SeatInterruption is thrown when one or more Issues stop an operation. It
/// carries the Issues themselves rather than a message, so the caller can tell
/// a suspension from a failure without parsing anything; the sentence for the
/// person is the consumer's to write.
public struct SeatInterruption: Error, Sendable, Equatable {

    /// The Issues that stopped the operation, in detection order.
    public let issues: [SeatIssue]

    public init(issues: [SeatIssue]) {
        self.issues = issues
    }

    /// True when at least one Issue is critical. A recoverable Issue hidden in
    /// the same batch never softens a critical one.
    public var isCritical: Bool {
        issues.contains(where: \.isCritical)
    }
}

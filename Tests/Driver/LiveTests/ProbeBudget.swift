//
//  ProbeBudget.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// ProbeBudget bounds one diagnostic run: how long all the phases together may
/// take, how long cleanup may take on its own, and how many reading pairs may be
/// collected.
///
/// These are limits of this harness and of nothing else. They are not a service
/// level for assignment, focus or any operation of the kit, and no number here
/// may be read as a budget the product promises. There is no renewal and no
/// retry: a run that reaches a limit stops and says which limit it reached.
/// A synchronous native call that blocks is not preempted by any of them.
struct ProbeBudget: Equatable {

    /// The whole phase sequence, cleanup excluded.
    let phaseNanoseconds: UInt64

    /// Cleanup, counted separately so a run that spent its phase budget still
    /// has a bounded chance to release what it created.
    let cleanupNanoseconds: UInt64

    /// The total number of reading pairs a run may collect.
    let maximumPairs: Int

    static let diagnosticDefault = ProbeBudget(
        phaseNanoseconds  : 20_000_000_000,
        cleanupNanoseconds:  2_000_000_000,
        maximumPairs      : 64
    )
}

/// ProbeStopReason is why the plan stopped where it did. It is recorded even
/// when the plan simply finished, so a report never has to be read by counting
/// the phases that are present.
enum ProbeStopReason: String, Codable, Equatable {

    case planCompleted

    /// The 20 second phase deadline was reached. Remaining phases are recorded
    /// as not run rather than omitted.
    case phaseDeadlineReached

    /// The pair cap was reached.
    case sampleCapReached

    /// A window operation failed, so the run stopped instead of continuing over
    /// a residue it has not accounted for.
    case operationFailed
}

//
//  ProbeCleanupRecord.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// ProbeCleanupStatus is how much of the release the probe could actually
/// establish. There is no case meaning "assumed fine": a close that was
/// requested and not verified is `unknownIncomplete`, because the request and
/// the process exiting are not, by themselves, evidence that the window server
/// dropped the surface.
enum ProbeCleanupStatus: String, Codable, Equatable {

    case verified
    case failed
    case unknownIncomplete
    case notAttempted
}

/// ProbeCleanupRecord is the end of a run: what was released, what is left, and
/// what went wrong on the way, with the original failure preserved.
///
/// A failing cleanup never overwrites the error that caused it, and a run that
/// failed never loses its partial report to a cleanup problem. Residual tokens
/// are listed explicitly so the report can describe an incomplete cleanup
/// instead of inventing a success.
struct ProbeCleanupRecord: Codable, Equatable {

    let status            : ProbeCleanupStatus
    let releasedTokenCount: Int
    let residualTokens    : [FixtureWindowToken]
    let notes             : [String]

    /// Errors from the phases, kept here so cleanup cannot mask them.
    let priorErrors: [String]

    static func notAttempted(reason: String) -> ProbeCleanupRecord {
        ProbeCleanupRecord(
            status            : .notAttempted,
            releasedTokenCount: 0,
            residualTokens    : [],
            notes             : [reason],
            priorErrors       : []
        )
    }

    /// The same record carrying the failures that happened before it, and a note
    /// when a claim of success arrived with residues still listed.
    func preserving(priorErrors errors: [String]) -> ProbeCleanupRecord {
        var amended = notes
        var claimed = status
        if !residualTokens.isEmpty && status == .verified {
            claimed = .unknownIncomplete
            amended.append("cleanup reported success while \(residualTokens.count) window(s) "
                + "were still registered, so it is recorded as incomplete")
        }
        return ProbeCleanupRecord(
            status            : claimed,
            releasedTokenCount: releasedTokenCount,
            residualTokens    : residualTokens,
            notes             : amended,
            priorErrors       : priorErrors + errors
        )
    }
}

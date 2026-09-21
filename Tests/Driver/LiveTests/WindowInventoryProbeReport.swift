//
//  WindowInventoryProbeReport.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// ProbeRunProvenance is where a report came from, as far as the run could tell.
///
/// Every field but the run identifier is optional and an unknown field stays
/// absent. A report that filled an unknown operating system in with a guess
/// would be a report whose provenance cannot be checked at all.
struct ProbeRunProvenance: Codable, Equatable {

    let runID                  : String
    let operatingSystemVersion : String?
    let architecture           : String?
    let buildIdentifier        : String?

    static func identified(
        runID                 : String,
        operatingSystemVersion: String? = nil,
        architecture          : String? = nil,
        buildIdentifier       : String? = nil
    ) -> ProbeRunProvenance {
        ProbeRunProvenance(
            runID                 : runID,
            operatingSystemVersion: operatingSystemVersion,
            architecture          : architecture,
            buildIdentifier       : buildIdentifier
        )
    }
}

/// WindowInventoryProbeReport is the versioned record of one diagnostic run:
/// provenance, every phase including the ones that did not run, every reading
/// pair with its discards and redactions, the stated limitations and the cleanup
/// result.
///
/// The verdict is diagnostic and unqualified. This report certifies nothing: not
/// an 8 ms budget, not helper membership, not the correctness of any product
/// path, and not the completeness of any inventory. It is instrumentation taken
/// before app assignment, and reading it as an acceptance result would be
/// reading it as the thing it says it is not.
struct WindowInventoryProbeReport: Codable, Equatable {

    static let formatVersion     = 1
    static let diagnosticVerdict = "diagnostic-unqualified"

    let version    : Int
    let provenance : ProbeRunProvenance
    let phases     : [ProbePhaseRecord]
    let pairs      : [InventoryReadingPair]
    let stopReason : ProbeStopReason
    let cleanup    : ProbeCleanupRecord
    let limitations: [String]
    let verdict    : String

    /// What a reader must not conclude from this report, written into the
    /// report itself rather than left in a commit message.
    static let statedLimitations: [String] = [
        "CGWindowListCopyWindowInfo assembles session wide window server metadata before any "
            + "filter is applied, so a reading touches windows this probe does not own.",
        "kCGWindowListOptionAll includes surfaces that were never shown, so presence in the all "
            + "reading is not visibility.",
        "The two readings of a pair are sequential and the pair is not atomic; a difference "
            + "between them is a difference between two instants of two lists.",
        "Absence from a reading, a reused Window ID and a failed reading prove neither closure "
            + "nor continuity nor membership.",
        "Only the fixture's own windows are persisted; every other row is kept as a redacted "
            + "counter with a reason, with no title, content or dictionary.",
        "The AppKit return of a window command is not evidence of a window server effect.",
        "A cleanup that requested a close records an unverified residue: this harness observes "
            + "no disappearance of a surface from the window server.",
        "The deadlines and the pair cap are limits of this harness, not a service level for "
            + "assignment or focus; a blocked synchronous native call is not preempted by them.",
        "This comparison is not a production adapter: it promotes no surface to a target, no "
            + "answer to proof of completeness, and no AppKit case to support for Qt or helpers.",
    ]

    static func make(
        provenance: ProbeRunProvenance,
        phases    : [ProbePhaseRecord],
        pairs     : [InventoryReadingPair],
        stopReason: ProbeStopReason,
        cleanup   : ProbeCleanupRecord
    ) -> WindowInventoryProbeReport {
        WindowInventoryProbeReport(
            version    : formatVersion,
            provenance : provenance,
            phases     : phases,
            pairs      : pairs,
            stopReason : stopReason,
            cleanup    : cleanup,
            limitations: statedLimitations,
            verdict    : diagnosticVerdict
        )
    }

    /// Pretty JSON, sorted, so a report can be read and diffed. Encoding a
    /// report must not fail for a value the run already produced, and the
    /// caller keeps the partial report even when this throws.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> WindowInventoryProbeReport {
        try JSONDecoder().decode(WindowInventoryProbeReport.self, from: data)
    }
}

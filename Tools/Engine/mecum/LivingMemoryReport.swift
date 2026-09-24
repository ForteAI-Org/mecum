//
//  LivingMemoryReport.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
import Memory
import SQLiteLivingMemory

/// LivingMemoryReport is the living-memory part of `mecum memory <app>`: for one application, its
/// sightings by window, and each experience with its phrase, step, proof, counts, history and the
/// recall decisions recorded about it.
///
/// It only reads. The store is opened read-only, so nothing is created, migrated or written, and no
/// decision is recorded for being printed. It says which of three situations it found: no store or
/// nothing recorded for the application, records without any recall decision yet, or a store that
/// could not be read, with the store's own error.
enum LivingMemoryReport {

    /// The most sighted names listed per window.
    static let sightingsPerWindow = 10

    static func lines(bundleID: String, knowledgeDirectory: URL) async -> [String] {
        let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledgeDirectory)
        do {
            let store = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            return try await lines(bundleID: bundleID, store: store, path: file.path)
        } catch SQLiteLivingMemoryError.missingStore {
            return ["living memory: nothing recorded yet (no store at \(file.path))"]
        } catch {
            return ["living memory: could not be read: \(error)"]
        }
    }

    private static func lines(
        bundleID: String,
        store   : SQLiteLivingMemoryStore,
        path    : String
    ) async throws -> [String] {
        let sightings = try await store.sightings(in: [bundleID])
        let experiences = try await store.experiences(in: [bundleID])
        guard !sightings.isEmpty || !experiences.isEmpty else {
            return ["living memory: nothing recorded for \(bundleID) in \(path)"]
        }
        var out = ["living memory (\(path)): \(experiences.count) experiences, \(sightings.count) sightings"]
        let windows = Dictionary(grouping: sightings, by: \.key.context.windowFamily).sorted { $0.key < $1.key }
        for (window, rows) in windows {
            let named = rows.sorted { $0.evidenceCount > $1.evidenceCount }.prefix(sightingsPerWindow)
                .map { "\($0.name) ×\($0.evidenceCount)" }
            out.append("  sighted in window '\(window)': " + named.joined(separator: ", "))
        }
        for record in experiences {
            out += try await describe(record, store: store)
        }
        return out
    }

    private static func describe(
        _ record: ExperienceRecord,
        store   : SQLiteLivingMemoryStore
    ) async throws -> [String] {
        var out = [
            "experience \(record.id.rawValue) in window '\(record.context.windowFamily)'",
            "  request: \"\(record.phrase)\"",
            "  step: \(record.step.tool.rawValue) '\(record.step.item)' in the control that read "
                + "'\(record.step.control)'",
            "  verified ×\(record.successCount), contradicted ×\(record.failureCount); last verified "
                + (record.lastVerifiedAt.map { $0.ISO8601Format() } ?? "never"),
        ]
        if let proof = record.latestProof { out.append("  proof: " + describe(proof)) }
        let history = try await store.history(of: record.id)
        out.append("  history: " + (history.isEmpty ? "none"
            : history.map { "\($0.event.at.ISO8601Format()) \(describe($0.event.outcome))" }.joined(separator: "; ")))
        let decisions = try await store.decisions(about: record.id)
        if decisions.isEmpty {
            out.append("  recall decisions: none recorded yet")
        } else {
            for decision in decisions {
                out.append("  recall \(decision.verdict.rawValue) \(decision.at.ISO8601Format()): \(decision.reason)")
            }
        }
        return out
    }

    private static func describe(_ proof: DropdownEvidence) -> String {
        let read: String = switch proof.readback {
            case .window(let value)     : "'\(value)' read in the window"
            case .controlCrop(let value): "'\(value)' read in the control crop"
            case .unreadable(let why)   : "unreadable (\(why.rawValue))"
        }
        let closure = proof.menuClosedByChoice ? "menu closed by the choice" : "menu closed otherwise"
        return "'\(proof.valueBefore)' before, \(read) after, \(closure), window \"\(proof.windowTitle)\""
    }

    private static func describe(_ outcome: ExperienceEvent.Outcome) -> String {
        switch outcome {
            case .verified                         : "verified"
            case .contradicted(.readbackShowed(let value)): "contradicted (read '\(value)')"
            case .contradicted(.userCorrection)    : "contradicted (corrected by the user)"
            case .noChange                         : "no change (already set)"
            case .uncertain(let why)               : "uncertain (\(why))"
        }
    }
}

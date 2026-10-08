//
//  JSONBrainImport.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 08/10/2026.
//

import Foundation
import Memory
import SQLiteMemory

/// JSONBrainImport copies the Brains of a JSON Knowledge directory, as main writes it (`<bundle id>.json`),
/// into the memory's archive, each as its application's projection, when the archive holds no Brain of that
/// application yet: a Brain already there is kept, never merged or replaced. The JSON files are only read,
/// never changed. Only the Brain is carried, with the file's counts and no evidence; not the files' window
/// states, menu commands or routes, and no history. What the agent learns afterwards adds to it.
///
/// `MemoryService` runs it once, on the JSON files beside an archive its open has just created, and
/// `mecum memory --import-json <dir>` runs it by hand on any directory.
nonisolated public enum JSONBrainImport {

    /// Outcome is what became of one application's Brain.
    public enum Outcome: Sendable, Equatable {
        case imported(anchors: Int, groups: Int, transitions: Int)
        /// The archive already held a Brain of the application, which stays as it is.
        case kept
        /// The archive refused it: the reason, in a sentence with no content of the agent's.
        case failed(String)
    }

    public struct Entry: Sendable, Equatable {
        public let bundleID: String
        public let outcome : Outcome
    }

    public struct Report: Sendable, Equatable {
        /// Every application found, in the order of its file name.
        public let entries: [Entry]

        public var imported: Int {
            entries.filter { if case .imported = $0.outcome { true } else { false } }.count
        }

        /// What was imported, kept and refused, in one sentence.
        public var summary: String {
            var anchors = 0, groups = 0, transitions = 0
            for case .imported(let a, let g, let t) in entries.map(\.outcome) { anchors += a; groups += g; transitions += t }
            let kept   = entries.filter { $0.outcome == .kept }.count
            let failed = entries.count - imported - kept
            return "\(imported) of \(entries.count) JSON Brains imported (\(anchors) anchors, \(groups) groups, "
                + "\(transitions) transitions)" + (kept > 0 ? ", \(kept) kept" : "") + (failed > 0 ? ", \(failed) refused" : "")
        }
    }

    /// The applications of a JSON Knowledge directory: its JSON files but the allowlist and the files a
    /// recovery put aside, in name order, decoded as main writes them. Hidden files, the copies under
    /// `.backup` and a file that cannot be read or decoded are left out.
    public static func applications(in directory: URL) -> [AppKnowledge] {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { file in
            // The allowlist and a quarantined file are the store's own, not an application's.
            let name = file.deletingPathExtension().lastPathComponent
            return file.pathExtension == "json" && name != "allowlist" && !name.contains(".corrupt-")
        }.sorted { $0.path < $1.path }
        let decoder = KnowledgeCoding.makeDecoder()
        return files.compactMap { file -> AppKnowledge? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(AppKnowledge.self, from: data)
        }
    }

    /// Imports each application's Brain into the archive the repository writes, one transaction each.
    public static func run(_ applications: [AppKnowledge], into brains: SQLiteBrainRepository, now: Date) async -> Report {
        var entries: [Entry] = []
        for app in applications {
            let brain = app.brain
            do {
                if try await brains.importProjection(brain, into: app.bundleID, now: now) {
                    entries.append(Entry(bundleID: app.bundleID, outcome: .imported(
                        anchors: brain.objects.count, groups: brain.groups.count, transitions: brain.transitions.count
                    )))
                } else {
                    entries.append(Entry(bundleID: app.bundleID, outcome: .kept))
                }
            } catch {
                entries.append(Entry(bundleID: app.bundleID, outcome: .failed(MemoryService.describe(error))))
            }
        }
        return Report(entries: entries)
    }
}

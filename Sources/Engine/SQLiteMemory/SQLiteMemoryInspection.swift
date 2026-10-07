//
//  SQLiteMemoryInspection.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
import SQLite3

/// SQLiteMemoryInspection says what an archive file is, for a diagnosis, without changing anything:
/// whether it is there, its size and its journal's, its schema version and whether its shape is
/// exactly the one this build creates, a few row counts when it is, and the copies and quarantined
/// files beside it. It opens the file read only, never creates it, never bootstraps, migrates,
/// recovers or copies, and reads nothing about the writes of a running process: those counters
/// live in each process's own memory.
public enum SQLiteMemoryInspection {

    /// Shape is how the file's schema compares with the one this build creates.
    public enum Shape: Sendable, Equatable {
        /// No file at the path.
        case missing
        /// A file with no schema of its own yet.
        case empty
        /// Exactly the shape this build creates.
        case matches
        /// Another shape: these objects are missing, extra or written differently (`type name`).
        case differs([String])
        /// The file could not be read as a database: the library's reason.
        case unreadable(String)
    }

    public struct Report: Sendable, Equatable {
        public let path: String
        public let bytes: Int64?
        public let journalBytes: Int64?
        public let schemaVersion: Int64?
        public let shape: Shape
        /// Row counts, by table, when the shape matches.
        public let counts: [String: Int]
        /// Copies beside the file, newest first.
        public let backups: [String]
        /// Files a recovery moved aside.
        public let quarantined: [String]
    }

    /// The tables whose rows a report counts.
    public static let countedTables = ["memory_events", "memory_agent_actions", "brain_apps", "brain_anchors",
                                       "brain_transitions", "brain_applications"]

    public static func inspect(_ url: URL) -> Report {
        let manager = FileManager.default
        func size(_ path: String) -> Int64? {
            (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
        let directory = url.deletingLastPathComponent()
        let siblings  = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted(by: >)
        let name      = url.lastPathComponent
        let backups   = siblings.filter { $0.hasPrefix("\(name).backup-") }
        let aside     = siblings.filter { $0.hasPrefix("\(name).corrupt-") }
        func report(_ shape: Shape, version: Int64? = nil, counts: [String: Int] = [:]) -> Report {
            Report(path: url.path, bytes: size(url.path), journalBytes: size(url.path + "-wal"), schemaVersion: version,
                   shape: shape, counts: counts, backups: backups, quarantined: aside)
        }
        guard manager.fileExists(atPath: url.path) else { return report(.missing) }
        // A file with its journal beside it may be in use: it is read through the journal, as any
        // reader does. One without is closed and whole: it is read as immutable, so the library makes
        // no journal of its own beside it.
        let inUse = manager.fileExists(atPath: url.path + "-wal") || manager.fileExists(atPath: url.path + "-shm")
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false, immutable: !inUse)
        } catch {
            return report(.unreadable("\(error)"))
        }
        defer { connection.close() }
        do {
            let version = try connection.query("PRAGMA user_version") { $0.integer(0) ?? 0 }.first ?? 0
            let found   = try SQLiteMemorySchema.objects(in: connection)
            guard !found.isEmpty else { return report(.empty, version: version) }
            let expected    = try SQLiteMemorySchema.objects(of: try SQLiteMemorySchema.text())
            let differences = SQLiteMemorySchema.differences(found: found, expected: expected)
            guard differences.isEmpty else { return report(.differs(differences), version: version) }
            var counts: [String: Int] = [:]
            for table in countedTables {
                // Table names are this module's own literals; nothing from a caller is spliced in.
                counts[table] = Int(try connection.query("SELECT count(*) FROM \(table)") { $0.integer(0) ?? 0 }.first ?? 0)
            }
            return report(.matches, version: version, counts: counts)
        } catch {
            return report(.unreadable("\(error)"))
        }
    }
}

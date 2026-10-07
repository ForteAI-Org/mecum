//
//  SQLiteMemoryInspection.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
import Memory
import SQLite3

/// SQLiteMemoryInspection says what an archive file is, for a diagnosis, without changing it: whether
/// it is there, its size and its log's, its schema version and what this build's open would make of
/// it, a few row counts when it would open it, and the copies and quarantined files beside it.
///
/// It reads the file as any reader does, with a read-only connection and the library's locks, all in
/// one read transaction, so version, shape and counts describe one committed state even while another
/// process writes. It takes the archive's presence lock shared first (`SQLiteMemoryPresence`): no
/// recovery moves the files while it reads, and while a recovery holds them it reads nothing and says
/// so. It never creates the archive, bootstraps, migrates, recovers or copies; the only file it may
/// make is the archive's empty lock file, the point every opener coordinates on, when the archive
/// was never opened by a build that makes it. The library may update the archive's WAL index
/// (`-shm`), shared memory that every reader updates and that holds no data. It reads nothing about
/// the writes of a running process: those counters live in each process's own memory.
public enum SQLiteMemoryInspection {

    /// Shape is what this build's ordinary open would make of the file as it was read.
    public enum Shape: Sendable, Equatable {
        /// No file at the path.
        case missing
        /// A database with no schema yet: Mecum's memory would create its schema in it, and a
        /// reader of an existing archive refuses it.
        case empty
        /// The schema this build opens: its version and exactly its shape.
        case current
        /// A file this build refuses and leaves as it is, and why: a newer version, another shape,
        /// tables of somebody else's.
        case refused(MemorySchemaMismatch)
        /// The file could not be read as a database: the library's reason.
        case unreadable(String)
        /// The file was not read, and why: a recovery holds it, or it cannot be read as it lies.
        case unavailable(String)
    }

    public struct Report: Sendable, Equatable {
        public let path: String
        public let bytes: Int64?
        public let journalBytes: Int64?
        /// The file's `user_version`, when it could be read.
        public let schemaVersion: Int64?
        public let shape: Shape
        /// Row counts, by table, when the shape is current.
        public let counts: [String: Int]
        /// Copies beside the file, newest first.
        public let backups: [String]
        /// Files a recovery moved aside.
        public let quarantined: [String]
    }

    /// The schema version this build opens.
    public static var supportedVersion: Int32 { SQLiteMemorySchema.version }

    /// The tables whose rows a report counts.
    public static let countedTables = ["memory_events", "memory_agent_actions", "brain_apps", "brain_anchors",
                                       "brain_transitions", "brain_applications"]

    /// How many times a read the library answered busy is tried, and the pause between two tries.
    static let busyAttempts          = 10
    static let busyPauseMicroseconds = UInt32(20_000)

    public static func inspect(_ url: URL) -> Report {
        inspect(url, betweenReads: nil)
    }

    /// The same, with a test's seam, for the package's tests only: `betweenReads` runs inside the read
    /// transaction, once the version was read and before the schema and the counts are.
    package static func inspect(_ url: URL, betweenReads: (() -> Void)?) -> Report {
        let manager = FileManager.default
        func size(_ path: String) -> Int64? {
            (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
        func report(_ shape: Shape, version: Int64? = nil, counts: [String: Int] = [:]) -> Report {
            let directory = url.deletingLastPathComponent()
            let siblings  = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted(by: >)
            let name      = url.lastPathComponent
            return Report(path: url.path, bytes: size(url.path), journalBytes: size(url.path + "-wal"),
                          schemaVersion: version, shape: shape, counts: counts,
                          backups: siblings.filter { $0.hasPrefix("\(name).backup-") },
                          quarantined: siblings.filter { $0.hasPrefix("\(name).corrupt-") })
        }
        // A missing archive gets no lock file either: nothing is made beside a file that is not there.
        guard manager.fileExists(atPath: url.path) else { return report(.missing) }
        let presence: SQLiteMemoryPresence
        do {
            guard let taken = try SQLiteMemoryPresence.take(.shared, of: url) else {
                return report(.unavailable("a recovery holds the archive; nothing was read"))
            }
            presence = taken
        } catch {
            return report(.unavailable("the archive's presence lock could not be taken: \(error)"))
        }
        defer { presence.release() }
        guard manager.fileExists(atPath: url.path) else { return report(.missing) }
        var attempt = 0
        while true {
            attempt += 1
            switch read(url, betweenReads: betweenReads) {
            case .read(let shape, let version, let counts):
                return report(shape, version: version, counts: counts)
            case .busy where attempt < busyAttempts:
                usleep(busyPauseMicroseconds)
            case .busy:
                return report(.unavailable("the library answered busy \(busyAttempts) times; nothing was read"))
            case .failed(let failure):
                if failure.primary == SQLITE_CANTOPEN, isWriteAheadLogged(url),
                   !manager.fileExists(atPath: url.path + "-shm") {
                    return report(.unavailable(
                        "a WAL archive whose log files are not beside it: a reader cannot make them without "
                        + "changing the directory; open it with Mecum, or inspect it with its -wal and -shm"
                    ))
                }
                return report(.unreadable("\(failure)"))
            }
        }
    }

    private enum Reading {
        case read(Shape, version: Int64?, counts: [String: Int])
        case busy
        case failed(SQLiteConnection.Failure)
    }

    /// One read of the file in one read transaction: the version, what the store's open would decide
    /// (the same inspection), and the counts when the schema is current.
    private static func read(_ url: URL, betweenReads: (() -> Void)?) -> Reading {
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
        } catch let failure as SQLiteConnection.Failure {
            return .failed(failure)
        } catch {
            return .read(.unreadable("\(error)"), version: nil, counts: [:])
        }
        defer { connection.close() }
        var version: Int64?
        do {
            let expected = try SQLiteMemoryStore.Expected(ddl: try SQLiteMemorySchema.text())
            try connection.execute("BEGIN")
            defer { _ = try? connection.execute("COMMIT") }
            version = try connection.query("PRAGMA user_version") { $0.integer(0) ?? 0 }.first ?? 0
            betweenReads?()
            switch try SQLiteMemoryStore.inspect(connection, expected: expected) {
            case .empty:
                return .read(.empty, version: version, counts: [:])
            case .current:
                var counts: [String: Int] = [:]
                for table in countedTables {
                    // Table names are this module's own literals; nothing from a caller is spliced in.
                    counts[table] = Int(try connection.query("SELECT count(*) FROM \(table)") { $0.integer(0) ?? 0 }.first ?? 0)
                }
                return .read(.current, version: version, counts: counts)
            }
        } catch MemoryStoreError.schema(let mismatch) {
            return .read(.refused(mismatch), version: version, counts: [:])
        } catch let failure as SQLiteConnection.Failure {
            return failure.isBusy ? .busy : .failed(failure)
        } catch {
            return .read(.unreadable("\(error)"), version: version, counts: [:])
        }
    }

    /// Whether the file's header says it is in WAL mode: read and write versions 2, bytes 18 and 19.
    private static func isWriteAheadLogged(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        return header[18] == 2 && header[19] == 2
    }
}

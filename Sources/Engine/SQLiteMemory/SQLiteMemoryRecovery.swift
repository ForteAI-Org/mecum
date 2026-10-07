//
//  SQLiteMemoryRecovery.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
import Memory
import SQLite3

/// SQLiteMemoryRecovery replaces an archive the library calls corrupt or not a database: it moves the
/// file aside with its journal, as `<archive>.corrupt-<stamp>`, never deleting anything, and puts the
/// newest sound copy in its place, or none, so the memory starts empty.
///
/// All of it happens under the archive's presence lock taken exclusive, without waiting
/// (`SQLiteMemoryPresence`). While anybody holds the archive (a store of any participating process, a
/// diagnosis) the recovery is refused and touches nothing. Once the lock is held, the archive is
/// read again: another process may have recovered it since the error that led here, and a file that
/// now reads is left as it is. The copy is checked before anything moves, placed by an exclusive
/// rename, and the file in place read once more before the lock is let go. Whoever opens next takes
/// the lock shared; the lock passes from exclusive to free to shared, so a process that took it in
/// between finds the recovered archive and leaves it as it is.
package enum SQLiteMemoryRecovery {

    package enum Outcome: Sendable, Equatable {

        /// Another holder has the archive: nothing was read, moved or copied.
        case inUse

        /// Under the exclusive lock the archive was not corrupt, or not there: nothing was touched.
        case notCorrupt

        /// The archive and its journal were moved to `aside`; the copy `restored` took its place, or
        /// none did and the memory starts empty.
        case recovered(aside: String, restored: String?)
    }

    /// Recovers the archive at the URL as the type describes. `copies` lists the candidate copies,
    /// newest first, and is read under the lock; `stamp` names the files moved aside. `whileHeld` runs
    /// after the work, with the exclusive lock still held: a test's seam, for the package's tests only.
    /// Throws when a file could not be moved or copied; what was moved by then stays where it went.
    package static func recover(
        _ archive: URL,
        copies   : () -> [URL],
        stamp    : String,
        whileHeld: (() -> Void)? = nil
    ) throws -> Outcome {
        guard let lock = try SQLiteMemoryPresence.take(.exclusive, of: archive) else { return .inUse }
        defer { lock.release() }
        let outcome = try recoverHolding(archive, copies: copies, stamp: stamp)
        whileHeld?()
        return outcome
    }

    private static func recoverHolding(_ archive: URL, copies: () -> [URL], stamp: String) throws -> Outcome {
        let manager = FileManager.default
        guard manager.fileExists(atPath: archive.path), try isCorrupt(archive) else { return .notCorrupt }
        let expected = try SQLiteMemoryStore.Expected(ddl: try SQLiteMemorySchema.text())
        let sound    = copies().first { isSound($0, expected: expected) }
        let directory = archive.deletingLastPathComponent()
        let aside     = "\(archive.lastPathComponent).corrupt-\(stamp)"
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: archive.path + suffix)
            guard manager.fileExists(atPath: file.path) else { continue }
            try manager.moveItem(at: file, to: directory.appendingPathComponent(aside + suffix))
        }
        guard let sound else { return .recovered(aside: aside, restored: nil) }
        let placing = directory.appendingPathComponent(".\(archive.lastPathComponent).restoring-\(UUID().uuidString)")
        do {
            try manager.copyItem(at: sound, to: placing)
            guard renamex_np(placing.path, archive.path, UInt32(RENAME_EXCL)) == 0 else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: archive.path])
            }
        } catch {
            // The placing file is this call's own copy, never the copy it came from.
            try? manager.removeItem(at: placing)
            throw error
        }
        guard isSound(archive, expected: expected, thorough: false) else {
            // Not expected of a copy that was just checked; kept beside the rest, and the memory starts empty.
            try manager.moveItem(at: archive, to: directory.appendingPathComponent(aside + ".restored"))
            return .recovered(aside: aside, restored: nil)
        }
        return .recovered(aside: aside, restored: sound.lastPathComponent)
    }

    /// Whether the library still calls the file corrupt or not a database, reading the header, the
    /// version and the schema as the store's open does, read only and in one read transaction, so the
    /// check itself writes nothing (no checkpoint at its close). Any other answer, readable or failing
    /// for another reason, is not a corruption, and the file is left as it is.
    static func isCorrupt(_ archive: URL) throws -> Bool {
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: archive.path, readOnly: true, mayCreate: false)
        } catch let failure as SQLiteConnection.Failure {
            return isCorruption(failure)
        }
        defer { connection.close() }
        do {
            try connection.execute("BEGIN")
            defer { _ = try? connection.execute("COMMIT") }
            _ = try connection.query("PRAGMA user_version") { $0.integer(0) }
            _ = try connection.query("SELECT count(*) FROM sqlite_schema") { $0.integer(0) }
            return false
        } catch let failure as SQLiteConnection.Failure {
            return isCorruption(failure)
        }
    }

    private static func isCorruption(_ failure: SQLiteConnection.Failure) -> Bool {
        failure.primary == SQLITE_CORRUPT || failure.primary == SQLITE_NOTADB
    }

    /// Whether a file reads as an archive of this build's schema; `thorough` adds the library's
    /// `quick_check` of every page. Read only, in one read transaction.
    private static func isSound(_ file: URL, expected: SQLiteMemoryStore.Expected, thorough: Bool = true) -> Bool {
        guard let connection = try? SQLiteConnection(path: file.path, readOnly: true, mayCreate: false) else { return false }
        defer { connection.close() }
        do {
            try connection.execute("BEGIN")
            defer { _ = try? connection.execute("COMMIT") }
            if thorough, try connection.query("PRAGMA quick_check") { try $0.text(0) ?? "" } != ["ok"] { return false }
            return try SQLiteMemoryStore.inspect(connection, expected: expected) == .current
        } catch {
            return false
        }
    }
}

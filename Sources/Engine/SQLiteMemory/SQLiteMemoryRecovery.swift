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
/// now reads is left as it is. The copy is checked before anything moves.
///
/// Before it moves anything, the recovery writes its record beside the archive, `<archive>.recovering`:
/// the name the files move to and the copy that takes their place. The record goes only once the copy
/// is in place and reads, or once the files moved aside when there is no copy. While it is there no
/// store opens the archive, so no open makes an empty archive where a recovery stopped half way
/// (`MemoryStoreError.Unavailability.interruptedRecovery`); the next recovery completes it from the
/// record alone, never choosing another copy, or refuses with the files kept and says why.
package enum SQLiteMemoryRecovery {

    package enum Outcome: Sendable, Equatable {

        /// Another holder has the archive: nothing was read, moved or copied.
        case inUse

        /// Under the exclusive lock the archive was not corrupt, or not there: nothing was touched.
        case notCorrupt

        /// The archive and its journal were moved to `aside`; the copy `restored` took its place, or
        /// none did and the memory starts empty.
        case recovered(aside: String, restored: String?)

        /// A recovery that had stopped half way was completed from its record: the same as
        /// `recovered`, for a recovery an earlier process began.
        case resumed(aside: String, restored: String?)
    }

    /// Stage is a point between the recovery's file operations, where a test's seam may stop it.
    package enum Stage: String, Sendable, CaseIterable {
        /// The record is written and nothing has moved.
        case recorded
        /// The files are aside and the copy is not in place yet.
        case movedAside
        /// The copy is in place and reads, and the record is still there.
        case published
        /// The record is gone, and the exclusive lock is still held.
        case finished
    }

    /// Record is what a recovery writes before it moves anything: where the files go and which copy
    /// takes their place, if any.
    struct Record: Codable, Equatable {
        let aside      : String
        let restoring  : String?
        let startedAtMS: Int64
        let process    : Int32
    }

    /// The record file of the archive at the URL.
    static func recordPath(of archive: URL) -> String { archive.path + ".recovering" }

    /// What the record beside the archive says, when a recovery began and has not finished: a
    /// sentence for an error or a diagnosis. Read without the lock: under a shared presence it means
    /// a recovery that stopped, since one in progress holds the lock exclusive.
    package static func pending(of archive: URL) -> String? {
        let path = recordPath(of: archive)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return "a recovery of the archive did not finish and its record \(path) cannot be read; every file is kept"
        }
        return "a recovery of the archive did not finish: its files were to move to \(record.aside) and "
            + (record.restoring.map { "the copy \($0) to take their place" } ?? "no copy to take their place")
            + "; every file is kept, and the record is \(path)"
    }

    /// Recovers the archive at the URL as the type describes, or completes the recovery its record
    /// says stopped half way. `copies` lists the candidate copies, newest first, and is read under the
    /// lock; `stamp` names the files moved aside. `at` is a test's seam, for the package's tests only:
    /// it runs at each stage with the exclusive lock held, and an error it throws stops the recovery
    /// there, as a process that ended there would. Throws when a file could not be moved or copied,
    /// and when a recovery that stopped cannot be completed from its record
    /// (`unavailable(.interruptedRecovery)`); what was moved by then stays where it went, and so does
    /// the record.
    package static func recover(
        _ archive: URL,
        copies   : () -> [URL],
        stamp    : String,
        at stage : ((Stage) throws -> Void)? = nil
    ) throws -> Outcome {
        guard let lock = try SQLiteMemoryPresence.take(.exclusive, of: archive) else { return .inUse }
        defer { lock.release() }
        let stage = stage ?? { _ in }
        let expected = try SQLiteMemoryStore.Expected(ddl: try SQLiteMemorySchema.text())
        if FileManager.default.fileExists(atPath: recordPath(of: archive)) {
            let record = try readRecord(of: archive)
            try resume(archive, record, expected: expected, at: stage)
            try stage(.finished)
            return .resumed(aside: record.aside, restored: record.restoring)
        }
        guard FileManager.default.fileExists(atPath: archive.path), try isCorrupt(archive) else { return .notCorrupt }
        let sound  = copies().first { isSound($0, expected: expected) }
        let record = Record(aside: "\(archive.lastPathComponent).corrupt-\(stamp)", restoring: sound?.lastPathComponent,
                            startedAtMS: Int64(Date().timeIntervalSince1970 * 1000), process: getpid())
        try write(record, of: archive)
        try stage(.recorded)
        try complete(archive, record, expected: expected, at: stage)
        try stage(.finished)
        return .recovered(aside: record.aside, restored: record.restoring)
    }

    /// Completes a recovery from its record. The file at the archive's place is the copy already
    /// published, when it is that copy byte for byte; a file that reads as an archive and is not the
    /// recorded copy is not one the recovery made, so nothing moves and the recovery is refused; any
    /// other file is the original the recovery found corrupt and moves aside as recorded.
    private static func resume(_ archive: URL, _ record: Record, expected: SQLiteMemoryStore.Expected,
                               at stage: (Stage) throws -> Void) throws {
        let directory = archive.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: archive.path) {
            if let name = record.restoring,
               FileManager.default.contentsEqual(atPath: archive.path, andPath: directory.appendingPathComponent(name).path),
               isSound(archive, expected: expected, thorough: false) {
                try removeRecord(of: archive)
                return
            }
            if isSound(archive, expected: expected, thorough: false) {
                throw refusal("the file at the archive's place reads as an archive but is not the copy the recovery "
                              + "recorded; nothing was moved", archive)
            }
        }
        try complete(archive, record, expected: expected, at: stage)
    }

    /// Moves aside what is still at the archive's place, the logs before the file so no log of the old
    /// file is ever left beside a copy, places the recorded copy by an exclusive rename and reads it,
    /// then removes the record. A destination already taken, a recorded copy that is gone or does not
    /// read, and a copy that fails to land are refusals: the record stays and nothing is guessed.
    private static func complete(_ archive: URL, _ record: Record, expected: SQLiteMemoryStore.Expected,
                                 at stage: (Stage) throws -> Void) throws {
        let manager   = FileManager.default
        let directory = archive.deletingLastPathComponent()
        for suffix in ["-wal", "-shm", ""] {
            let source = archive.path + suffix
            guard manager.fileExists(atPath: source) else { continue }
            let destination = directory.appendingPathComponent(record.aside + suffix)
            guard !manager.fileExists(atPath: destination.path) else {
                throw refusal("both \(URL(fileURLWithPath: source).lastPathComponent) and \(destination.lastPathComponent) "
                              + "exist; nothing more was moved", archive)
            }
            try manager.moveItem(at: URL(fileURLWithPath: source), to: destination)
        }
        syncDirectory(directory)
        try stage(.movedAside)
        if let name = record.restoring {
            let copy = directory.appendingPathComponent(name)
            guard isSound(copy, expected: expected) else {
                throw refusal("the copy \(name) the recovery recorded is gone or does not read as an archive of "
                              + "this build", archive)
            }
            let placing = directory.appendingPathComponent(".\(archive.lastPathComponent).restoring-\(UUID().uuidString)")
            do {
                try manager.copyItem(at: copy, to: placing)
                guard renamex_np(placing.path, archive.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: archive.path])
                }
            } catch {
                // The placing file is this call's own copy, never the copy it came from.
                try? manager.removeItem(at: placing)
                throw refusal("the copy \(name) could not be put in place: \(error.localizedDescription)", archive)
            }
            syncDirectory(directory)
            guard isSound(archive, expected: expected, thorough: false) else {
                throw refusal("the copy \(name) was put in place and does not read", archive)
            }
            try stage(.published)
        }
        try removeRecord(of: archive)
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
            if thorough, try connection.query("PRAGMA quick_check", [], { try $0.text(0) ?? "" }) != ["ok"] { return false }
            return try SQLiteMemoryStore.inspect(connection, expected: expected) == .current
        } catch {
            return false
        }
    }

    // MARK: The record

    /// Writes the record durably before anything moves: a file of its own, synced, renamed into place
    /// without replacing another, and the directory synced.
    private static func write(_ record: Record, of archive: URL) throws {
        let directory = archive.deletingLastPathComponent()
        let writing   = directory.appendingPathComponent(".\(archive.lastPathComponent).recovering-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: writing.path, contents: nil) else {
            throw refusal("its record could not be written; nothing was moved", archive)
        }
        do {
            let handle = try FileHandle(forWritingTo: writing)
            defer { try? handle.close() }
            try handle.write(contentsOf: try JSONEncoder().encode(record))
            try handle.synchronize()
            guard renamex_np(writing.path, recordPath(of: archive), UInt32(RENAME_EXCL)) == 0 else {
                throw CocoaError(.fileWriteFileExists)
            }
        } catch {
            try? FileManager.default.removeItem(at: writing)
            throw refusal("its record could not be written (\(error.localizedDescription)); nothing was moved", archive)
        }
        syncDirectory(directory)
    }

    private static func readRecord(of archive: URL) throws -> Record {
        guard let data = FileManager.default.contents(atPath: recordPath(of: archive)),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            throw refusal("its record cannot be read", archive)
        }
        return record
    }

    private static func removeRecord(of archive: URL) throws {
        try FileManager.default.removeItem(atPath: recordPath(of: archive))
        syncDirectory(archive.deletingLastPathComponent())
    }

    /// Makes the directory's entries durable: the record, the moves and the rename.
    private static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }

    private static func refusal(_ why: String, _ archive: URL) -> MemoryStoreError {
        .unavailable(.interruptedRecovery("the recovery of \(archive.lastPathComponent) cannot be completed: \(why); "
                                          + "every file is kept, and its record, if written, is \(recordPath(of: archive))"))
    }
}

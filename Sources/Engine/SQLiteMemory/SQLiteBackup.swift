//
//  SQLiteBackup.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import SQLite3

/// SQLiteBackup is one online copy of a database through the library's backup API, page by page,
/// from a source connection to a destination connection. The owner steps it, checking for
/// cancellation between steps, and finishes it whatever happened: a backup left unfinished keeps
/// both connections from closing.
///
/// The copy is consistent as of the source connection's read transaction. The owner opens that
/// transaction before the first step and holds it until after the last, so the pages the steps
/// read never change underneath them and no commit by another connection restarts the copy from
/// its first page. A copy taken without that transaction would restart at every external commit.
final class SQLiteBackup {

    /// Progress is what one step left: the source's page count as of that step, and how many pages
    /// are still to copy. Zero remaining means the copy is complete and committed on the
    /// destination.
    struct Progress: Equatable {
        let pageCount: Int
        let remaining: Int
    }

    private let destination: SQLiteConnection
    private var handle     : OpaquePointer?

    /// Attaches to both connections. The destination must be a database the owner opened for this
    /// copy alone; its contents are replaced by the copy.
    init(from source: SQLiteConnection, to destination: SQLiteConnection) throws {
        let destinationHandle = try destination.openHandle()
        guard let handle = sqlite3_backup_init(destinationHandle, "main", try source.openHandle(), "main") else {
            throw SQLiteConnection.Failure(
                primary : sqlite3_errcode(destinationHandle) & 0xFF,
                extended: sqlite3_extended_errcode(destinationHandle),
                message : String(cString: sqlite3_errmsg(destinationHandle))
            )
        }
        self.destination = destination
        self.handle      = handle
    }

    deinit { try? finish() }

    /// Copies up to `pages` pages and answers the progress. A busy source answers `SQLITE_BUSY`
    /// as a failure the owner may retry after a pause; the step copied nothing then.
    func step(pages: Int32) throws -> Progress {
        guard let handle else {
            throw SQLiteConnection.Failure(
                primary : SQLITE_MISUSE,
                extended: SQLITE_MISUSE,
                message : "the backup is finished"
            )
        }
        let status = sqlite3_backup_step(handle, pages)
        switch status {
        case SQLITE_OK, SQLITE_DONE:
            return Progress(
                pageCount: Int(sqlite3_backup_pagecount(handle)),
                remaining: Int(sqlite3_backup_remaining(handle))
            )
        case SQLITE_BUSY, SQLITE_LOCKED:
            throw SQLiteConnection.Failure(
                primary : status & 0xFF,
                extended: status,
                message : "the source database is locked"
            )
        default:
            throw SQLiteConnection.Failure(
                primary : status & 0xFF,
                extended: sqlite3_extended_errcode(try destination.openHandle()),
                message : String(cString: sqlite3_errmsg(try destination.openHandle()))
            )
        }
    }

    /// Releases the backup object. Throws the error the copy ended with, if it ended with one; a
    /// second finish is a no-op. The destination holds a complete copy only when every step ran
    /// to zero remaining before this.
    func finish() throws {
        guard let handle else { return }
        self.handle = nil
        let status = sqlite3_backup_finish(handle)
        guard status == SQLITE_OK else {
            throw SQLiteConnection.Failure(
                primary : status & 0xFF,
                extended: status,
                message : "the backup ended with error \(status)"
            )
        }
    }
}

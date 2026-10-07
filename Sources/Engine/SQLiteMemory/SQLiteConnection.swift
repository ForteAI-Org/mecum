//
//  SQLiteConnection.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import SQLite3

/// SQLiteConnection is one `sqlite3*` handle with one owner, used from one isolation domain at a
/// time and closed when the owner closes it or lets it go. Its methods answer the library's own
/// result: a `Failure` carries the primary and extended code and the message, and sorting that
/// into the memory store's taxonomy is the owner's job, because one code means different things
/// in different phases.
///
/// The busy timeout is zero on purpose: a lock that is not free answers `SQLITE_BUSY` at once, and
/// the owner waits in its own cancellable way, outside any transaction.
final class SQLiteConnection {

    /// Failure is one result code the library returned, with its extended refinement and message.
    struct Failure: Error, Equatable {

        let primary : Int32
        let extended: Int32
        let message : String

        var isBusy  : Bool { primary == SQLITE_BUSY }
        var isLocked: Bool { primary == SQLITE_LOCKED }
    }

    /// CheckpointResult is what one passive checkpoint of the write-ahead log did: how many frames
    /// the log held and how many of them reached the database file. Fewer than all is not an
    /// error: a reader still on an older snapshot keeps the rest in the log for next time.
    struct CheckpointResult: Equatable {

        let frames      : Int
        let checkpointed: Int

        /// Another connection was checkpointing at the same time, so this one did nothing.
        let wasBusy: Bool
    }

    let path: String

    private var handle: OpaquePointer?

    /// Opens the database at the path, creating the file unless `readOnly` or `mayCreate` is false.
    /// A directory that does not exist or cannot be written, and a missing file that may not be
    /// created, answer `SQLITE_CANTOPEN` here; a file that is not a database answers `SQLITE_NOTADB`
    /// at its first statement, not here.
    ///
    /// `immutable` opens the file read only as one that nothing else changes: no lock, no journal, no
    /// file made beside it. Only for a diagnosis of a file no connection holds, whose journal is gone.
    init(path: String, readOnly: Bool = false, mayCreate: Bool = true, immutable: Bool = false) throws {
        var handle: OpaquePointer?
        var flags  = readOnly || immutable ? SQLITE_OPEN_READONLY
            : (mayCreate ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE)
        var name   = path
        if immutable {
            flags |= SQLITE_OPEN_URI
            name   = URL(fileURLWithPath: path).absoluteString + "?mode=ro&immutable=1"
        }
        let status = sqlite3_open_v2(name, &handle, flags, nil)
        guard status == SQLITE_OK, let opened = handle else {
            let failure = Failure(
                primary : status & 0xFF,
                extended: handle.map { sqlite3_extended_errcode($0) } ?? status,
                message : handle.map { String(cString: sqlite3_errmsg($0)) } ?? "the database could not be opened"
            )
            sqlite3_close_v2(handle)
            throw failure
        }
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, 0)
        self.path   = path
        self.handle = opened
    }

    deinit { close() }

    var isOpen: Bool { handle != nil }

    /// Whether a transaction is open on this connection, as the library sees it.
    var isInTransaction: Bool {
        guard let handle else { return false }
        return sqlite3_get_autocommit(handle) == 0
    }

    /// The rows the most recent statement changed.
    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes64(handle))
    }

    /// Limit is one of the library's per-connection limits this module reads or lowers.
    enum Limit: Int32 {
        /// The longest text or blob, in bytes: `SQLITE_LIMIT_LENGTH`.
        case length = 0
    }

    /// Reads a limit, or lowers it when a value is given, answering the value in force before the
    /// call. A value above the compiled maximum is clamped by the library; -1 on a closed handle.
    @discardableResult
    func limit(_ limit: Limit, to value: Int32? = nil) -> Int32 {
        guard let handle else { return -1 }
        return sqlite3_limit(handle, limit.rawValue, value ?? -1)
    }

    /// Closes the handle. Statements still open are finalized by the library; a second close is
    /// a no-op.
    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    /// Runs one or more statements without bindings: pragmas, transaction boundaries, the schema.
    func execute(_ sql: String) throws {
        let handle = try openHandle()
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw Failure(
                primary : status & 0xFF,
                extended: sqlite3_extended_errcode(handle),
                message : message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            )
        }
    }

    /// Prepares one statement. The caller finalizes it, normally with `defer`, before the
    /// transaction ends.
    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(connection: try openHandle(), sql: sql)
    }

    /// Runs one statement with bound values to completion and answers the rows it changed.
    @discardableResult
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bind(bindings)
        while try statement.step() {}
        return changes
    }

    /// Runs one query with bound values and maps every row inside the call; the statement is
    /// finalized before this returns, so no cursor outlives it.
    func query<T>(
        _ sql     : String,
        _ bindings: [SQLiteValue] = [],
        _ row     : (SQLiteStatement.Row) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bind(bindings)
        var results: [T] = []
        while try statement.step() {
            results.append(try row(statement.row))
        }
        return results
    }

    /// Runs one passive checkpoint of the write-ahead log: as many frames as can be copied without
    /// waiting for any reader or writer, then a sync of the database file when all of them were.
    /// It never invokes a busy handler and never truncates or restarts the log, so it is safe with
    /// other processes on the file. Must be called outside any transaction.
    func checkpoint() throws -> CheckpointResult {
        let handle = try openHandle()
        var frames      : Int32 = -1
        var checkpointed: Int32 = -1
        let status = sqlite3_wal_checkpoint_v2(handle, "main", SQLITE_CHECKPOINT_PASSIVE, &frames, &checkpointed)
        switch status {
        case SQLITE_OK:
            return CheckpointResult(frames: Int(frames), checkpointed: Int(checkpointed), wasBusy: false)
        case SQLITE_BUSY:
            return CheckpointResult(frames: Int(max(frames, 0)), checkpointed: Int(max(checkpointed, 0)), wasBusy: true)
        default:
            throw Failure(
                primary : status & 0xFF,
                extended: sqlite3_extended_errcode(handle),
                message : String(cString: sqlite3_errmsg(handle))
            )
        }
    }

    /// The raw handle, for the module's own wrappers of library objects that take one. Throws
    /// once the connection is closed.
    func openHandle() throws -> OpaquePointer {
        guard let handle else {
            throw Failure(primary: SQLITE_MISUSE, extended: SQLITE_MISUSE, message: "the connection is closed")
        }
        return handle
    }
}

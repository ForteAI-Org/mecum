//
//  SQLiteConnection.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation
import SQLite3

/// SQLiteConnection is one open database handle and the few statement shapes the store needs.
///
/// It is not `Sendable`: the owning actor creates it, uses it only from its own isolation, and
/// closes it on deinitialization. Every call runs to completion synchronously, so a transaction
/// opened by `transaction(_:)` never stays open across a suspension.
final class SQLiteConnection {

    /// Value is one bound parameter.
    enum Value {
        case text(String)
        case integer(Int64)
        case null
    }

    /// Row reads the columns of the current result row; valid only inside the row callback.
    struct Row {
        fileprivate let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: bytes)
        }

        func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    }

    let path: String
    private let handle: OpaquePointer

    /// Opens the file with the given `sqlite3_open_v2` flags. Opening does not read the file, so a
    /// file that is not a database fails on its first statement, not here.
    init(path: String, flags: Int32) throws(SQLiteLivingMemoryError) {
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
            sqlite3_close_v2(opened)
            throw .sqlite(code: code, message: message)
        }
        self.path   = path
        self.handle = opened
        sqlite3_extended_result_codes(opened, 1)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements that bind nothing and return no rows.
    func execute(_ sql: String) throws(SQLiteLivingMemoryError) {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(code) }
    }

    /// Runs one statement, calling `row` for each result row.
    func query(
        _ sql     : String,
        _ bindings: [Value] = [],
        row       : (Row) throws -> Void = { _ in }
    ) throws {
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard code == SQLITE_OK, let statement = prepared else { throw failure(code) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bound = switch value {
                case .text(let text)      : sqlite3_bind_text(statement, index, text, -1, Self.transient)
                case .integer(let integer): sqlite3_bind_int64(statement, index, integer)
                case .null                : sqlite3_bind_null(statement, index)
            }
            guard bound == SQLITE_OK else { throw failure(bound) }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw failure(step) }
            try row(Row(statement: statement))
        }
    }

    /// The first column of the first row as an integer, or nil when there is no row.
    func integer(_ sql: String, _ bindings: [Value] = []) throws -> Int64? {
        var value: Int64?
        try query(sql, bindings) { row in if value == nil { value = row.integer(0) } }
        return value
    }

    /// Runs the body inside `BEGIN IMMEDIATE`, which takes the write lock before the first read so
    /// another connection cannot interleave a read-modify-write. Commits when the body returns;
    /// rolls back and rethrows the body's error when it throws, keeping that error if the rollback
    /// fails as well.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func failure(_ code: Int32) -> SQLiteLivingMemoryError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Tells SQLite to copy a bound string before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

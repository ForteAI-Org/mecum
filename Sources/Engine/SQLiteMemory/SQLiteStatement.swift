//
//  SQLiteStatement.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import SQLite3

/// SQLiteStatement is one prepared statement: bound by position, stepped to its rows, finalized by
/// its owner. A statement left with a pending row holds a read cursor on its table, and the next
/// write on that table from the same connection answers `SQLITE_LOCKED`, which is why every helper
/// in this module finalizes inside the call that prepared it.
///
/// Values cross this boundary whole. Text is bound and read by its UTF-8 length, never by a
/// terminating zero, so a NUL inside a text is content; an empty text stays a text and NULL stays
/// NULL. A text that is not valid UTF-8 is not decoded at all: reading it as text throws
/// `InvalidText`, and reading it as bytes answers what is stored. A statement is given exactly as
/// many values as it has parameters: fewer or more is a contract error, since the library would
/// otherwise bind NULL for what was not offered.
package final class SQLiteStatement {

    /// Row reads the columns of the statement's current row by position. It is valid only until
    /// the next `step`, `reset` or `finalize`; a column that is NULL reads as nil.
    package struct Row {

        fileprivate let handle: OpaquePointer

        package var columnCount: Int { Int(sqlite3_column_count(handle)) }

        package func isNull(_ index: Int) -> Bool {
            sqlite3_column_type(handle, Int32(index)) == SQLITE_NULL
        }

        package func integer(_ index: Int) -> Int64? {
            isNull(index) ? nil : sqlite3_column_int64(handle, Int32(index))
        }

        package func real(_ index: Int) -> Double? {
            isNull(index) ? nil : sqlite3_column_double(handle, Int32(index))
        }

        /// The column as text, by its byte length: a NUL inside it is kept. Bytes that are not
        /// valid UTF-8 are refused with `InvalidText`, which says where the first invalid sequence
        /// starts and nothing of the content; `bytes` still reads them.
        package func text(_ index: Int) throws -> String? {
            guard !isNull(index) else { return nil }
            let column = Int32(index)
            guard let base = sqlite3_column_text(handle, column) else { return "" }
            let count  = Int(sqlite3_column_bytes(handle, column))
            let buffer = UnsafeRawBufferPointer(start: base, count: count)
            if let valid = String(validating: buffer, as: UTF8.self) { return valid }
            throw InvalidText(column: index, byteCount: count, invalidByteOffset: Self.firstInvalidOffset(in: buffer))
        }

        /// The column's bytes, as a blob: an empty blob reads as `[]`, NULL as nil.
        package func bytes(_ index: Int) -> [UInt8]? {
            guard !isNull(index) else { return nil }
            let column = Int32(index)
            guard let base = sqlite3_column_blob(handle, column) else { return [] }
            let count = Int(sqlite3_column_bytes(handle, column))
            return Array(UnsafeRawBufferPointer(start: base, count: count))
        }

        /// Where the first sequence the codec rejects begins, scanning the bytes it accepted.
        private static func firstInvalidOffset(in buffer: UnsafeRawBufferPointer) -> Int {
            var iterator = buffer.makeIterator()
            var decoder  = UTF8()
            var offset   = 0
            while true {
                switch decoder.decode(&iterator) {
                case .scalarValue(let scalar): offset += scalar.utf8.count
                case .emptyInput             : return offset
                case .error                  : return offset
                }
            }
        }
    }

    /// InvalidText is a text column whose bytes are not valid UTF-8, found while reading a row.
    /// It is not a library failure and carries no library code: the library stored what it was
    /// given, and the refusal is this module's.
    struct InvalidText: Error, Equatable {
        let column           : Int
        let byteCount        : Int
        let invalidByteOffset: Int
    }

    private let connection : OpaquePointer
    private let handle     : OpaquePointer
    private var isFinalized = false

    init(connection: OpaquePointer, sql: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_prepare_v2(connection, sql, -1, &handle, nil)
        guard status == SQLITE_OK, let prepared = handle else {
            sqlite3_finalize(handle)
            throw SQLiteConnection.Failure(
                primary : status & 0xFF,
                extended: sqlite3_extended_errcode(connection),
                message : String(cString: sqlite3_errmsg(connection))
            )
        }
        self.connection = connection
        self.handle     = prepared
    }

    deinit { finalize() }

    /// The current row. Read it only after `step` answered true.
    var row: Row { Row(handle: handle) }

    /// How many parameters the statement has: the highest `?N` it names.
    var parameterCount: Int { Int(sqlite3_bind_parameter_count(handle)) }

    /// Releases the statement. Every other call after this is a defect; a second finalize is a no-op.
    func finalize() {
        guard !isFinalized else { return }
        isFinalized = true
        sqlite3_finalize(handle)
    }

    /// Binds the values by position, first value to `?1`, and refuses a count other than the
    /// statement's parameter count with `SQLITE_RANGE`. Text and blobs are copied by the library;
    /// one longer than its length limit is refused by the library with `SQLITE_TOOBIG`, whole.
    func bind(_ values: [SQLiteValue]) throws {
        let expected = parameterCount
        guard values.count == expected else {
            throw SQLiteConnection.Failure(
                primary : SQLITE_RANGE,
                extended: SQLITE_RANGE,
                message : "the statement takes \(expected) parameter(s); \(values.count) offered"
            )
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(handle, index)
            case .integer(let number):
                status = sqlite3_bind_int64(handle, index, number)
            case .real(let number):
                status = sqlite3_bind_double(handle, index, number)
            case .text(let text):
                status = Self.bindText(text, at: index, on: handle)
            case .blob(let bytes) where bytes.isEmpty:
                status = sqlite3_bind_zeroblob(handle, index, 0)
            case .blob(let bytes):
                status = bytes.withUnsafeBytes { buffer in
                    sqlite3_bind_blob64(handle, index, buffer.baseAddress, UInt64(buffer.count), Self.transient)
                }
            }
            guard status == SQLITE_OK else { throw failure(status) }
        }
    }

    /// Advances to the next row: true when a row is ready, false when the statement is done.
    func step() throws -> Bool {
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW : return true
        case SQLITE_DONE: return false
        default         : throw failure(status)
        }
    }

    /// Returns the statement to its initial state and clears its bindings, keeping it prepared.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    // Bound by its UTF-8 byte count: a length of -1 would stop at the first NUL and lose the rest.
    private static func bindText(_ text: String, at index: Int32, on handle: OpaquePointer) -> Int32 {
        var copy = text
        return copy.withUTF8 { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else {
                return sqlite3_bind_text64(handle, index, "", 0, transient, UInt8(SQLITE_UTF8))
            }
            let start = UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self)
            return sqlite3_bind_text64(handle, index, start, UInt64(buffer.count), transient, UInt8(SQLITE_UTF8))
        }
    }

    // `SQLITE_TRANSIENT` asks the library to copy the bytes: Swift's storage does not outlive the call.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func failure(_ status: Int32) -> SQLiteConnection.Failure {
        SQLiteConnection.Failure(
            primary : status & 0xFF,
            extended: sqlite3_extended_errcode(connection),
            message : String(cString: sqlite3_errmsg(connection))
        )
    }
}

/// SQLiteValue is one bound value in the library's five storage classes, typed at the binding site
/// so that no file name and no text of the agent's is ever spliced into SQL. NULL is a value a
/// caller offers on purpose; it is never what a missing value becomes.
package enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])
}

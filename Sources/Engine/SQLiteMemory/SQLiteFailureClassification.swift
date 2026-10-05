//
//  SQLiteFailureClassification.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Memory
import SQLite3

extension MemoryStoreError {

    /// Sorts one library failure by its primary code and the phase it was met in. A busy lock is
    /// contention, a lock inside the connection is `locked`, a constraint or a misuse is a contract
    /// error, and a device or file problem is `open` while opening and `failed` afterwards. A code
    /// the table does not name is a failure, never contention: an unknown condition is not retried.
    /// `cleanup` is what became of the transaction the failure interrupted, when there was one.
    init(_ failure: SQLiteConnection.Failure, phase: Phase, cleanup: MemoryStoreFault.Cleanup = .notNeeded) {
        let fault = MemoryStoreFault(
            code   : MemoryStoreFault.Code(primary: failure.primary, extended: failure.extended),
            phase  : phase,
            message: failure.message,
            cleanup: cleanup
        )
        switch failure.primary {
        case SQLITE_BUSY:
            self = .contention(fault, attempts: 1, waited: .zero)
        case SQLITE_LOCKED:
            self = .locked(fault)
        case SQLITE_CONSTRAINT, SQLITE_ERROR, SQLITE_MISUSE, SQLITE_RANGE, SQLITE_MISMATCH, SQLITE_TOOBIG,
             SQLITE_SCHEMA:
            self = .contract(fault)
        case SQLITE_INTERRUPT:
            self = .cancelled(phase)
        case SQLITE_CANTOPEN, SQLITE_NOTADB, SQLITE_PERM, SQLITE_AUTH, SQLITE_CORRUPT, SQLITE_FULL,
             SQLITE_IOERR, SQLITE_READONLY, SQLITE_NOMEM, SQLITE_PROTOCOL:
            self = (phase == .open || phase == .bootstrap) ? .open(fault) : .failed(fault)
        default:
            self = .failed(fault)
        }
    }

    /// The typed refusal of a text column that is not valid UTF-8: this module's, not the library's.
    init(_ invalid: SQLiteStatement.InvalidText) {
        self = .malformedText(MemoryTextFault(
            column           : invalid.column,
            byteCount        : invalid.byteCount,
            invalidByteOffset: invalid.invalidByteOffset
        ))
    }
}

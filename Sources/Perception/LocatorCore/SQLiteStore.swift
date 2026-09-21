import Foundation
import SQLite3

/// Minimal SQLite wrapper over the APPLE-SHIPPED system library (no package, no network — the
/// dependency invariant holds). One file, WAL journal, busy-timeout: exactly our topology of several
/// concurrent engine processes (chat's, Claude Desktop's, probes) sharing one living memory, where the
/// whole-file JSON stores can only do last-writer-wins.
/// `@unchecked Sendable`: the connection is opened FULLMUTEX and every call additionally holds `lock`,
/// so cross-actor use from the engine's async handlers is serialized twice over.
public final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA busy_timeout=500")
        exec("PRAGMA synchronous=NORMAL")
    }

    deinit { sqlite3_close(db) }

    /// Statement without binds (DDL, pragmas, transactions).
    @discardableResult
    public func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Bound statement, no result rows (INSERT/UPDATE/DELETE). Binds: String, Int, Double, nil.
    @discardableResult
    public func run(_ sql: String, _ binds: [Any?] = []) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runLocked(sql, binds)
    }

    /// Atomic multi-statement write: the connection lock is held across BEGIN…COMMIT, so a concurrent
    /// writer on this shared connection can NEVER interleave into the transaction. (Per-statement
    /// locking let two recordSightings nest BEGINs — SQLite rejects the inner one silently and the
    /// "transaction" stopped being one; found in adversarial review.) The closure gets a LOCKED runner;
    /// it must not call run/query/exec (NSLock is not reentrant — that would deadlock by design).
    public func transaction(_ body: (_ run: (String, [Any?]) -> Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        body { sql, binds in self.runLocked(sql, binds) }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Like `transaction`, but ALL-OR-NOTHING: the body reports success; on false (or a failed BEGIN)
    /// everything ROLLS BACK and the caller learns it. For migrations, where a silently half-applied
    /// batch is worse than no batch (adversarial review: an ignored SQLITE_BUSY mid-migration plus an
    /// unconditional version bump would have bricked the experience upsert permanently).
    @discardableResult
    public func transactionChecked(_ body: (_ run: (String, [Any?]) -> Bool) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        if body({ sql, binds in self.runLocked(sql, binds) }) {
            return sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
        }
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        return false
    }

    private func runLocked(_ sql: String, _ binds: [Any?]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Bound query returning rows as dictionaries (TEXT → String, INTEGER → Int, REAL → Double).
    public func query(_ sql: String, _ binds: [Any?] = []) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                default: break   // NULL/BLOB unused by our schema
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ stmt: OpaquePointer?, _ binds: [Any?]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }
}

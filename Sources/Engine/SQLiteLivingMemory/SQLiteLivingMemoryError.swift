//
//  SQLiteLivingMemoryError.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

/// SQLiteLivingMemoryError is why the SQLite store refused to open or to complete an operation.
///
/// No case is followed by a repair: the store never deletes, replaces or empties a file it cannot
/// use, so the caller can report the problem and the file stays for a person to inspect. A failed
/// operation was rolled back and left the database as it was.
public enum SQLiteLivingMemoryError: Error, Sendable, Equatable, CustomStringConvertible {

    /// A read-only open found no store at the path. Nothing was created.
    case missingStore(path: String)

    /// The file is not a readable SQLite database, for example a truncated or overwritten file.
    case unreadable(path: String, message: String)

    /// The file is a SQLite database that belongs to something else.
    case notALivingMemoryStore(path: String)

    /// The store was written by a newer schema than this build understands.
    case unsupportedSchemaVersion(path: String, found: Int, supported: Int)

    /// A read-only open found an older schema, which only a read-write open may migrate.
    case needsMigration(path: String, found: Int, current: Int)

    /// A write was attempted through a read-only store.
    case readOnly(path: String)

    /// A stored row did not decode. The row is kept as it is.
    case corruptRecord(table: String, key: String)

    /// SQLite reported an error. `SQLITE_BUSY` (5) means another connection held the write lock past
    /// the busy timeout; the operation had no effect and may be retried.
    case sqlite(code: Int32, message: String)

    public var description: String {
        switch self {
            case .missingStore(let path):
                "no living memory store at \(path)"
            case .unreadable(let path, let message):
                "the living memory store at \(path) is not a readable database (\(message)); it was left untouched"
            case .notALivingMemoryStore(let path):
                "\(path) is a database, but not a living memory store; it was left untouched"
            case .unsupportedSchemaVersion(let path, let found, let supported):
                "the living memory store at \(path) has schema \(found); this build supports up to \(supported)"
            case .needsMigration(let path, let found, let current):
                "the living memory store at \(path) has schema \(found) and needs migration to \(current); "
                    + "open it for writing to migrate"
            case .readOnly(let path):
                "the living memory store at \(path) is open read-only"
            case .corruptRecord(let table, let key):
                "a \(table) row (\(key)) in the living memory store did not decode; it was kept"
            case .sqlite(let code, let message):
                "SQLite error \(code): \(message)"
        }
    }
}

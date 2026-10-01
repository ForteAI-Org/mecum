//
//  SQLiteLivingMemoryStore+Opening.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation
import SQLite3

extension SQLiteLivingMemoryStore {

    /// Opens a connection and brings it to `schema`, or refuses without changing the file.
    ///
    /// The file is classified before anything is written: it must read as a database, and a
    /// database with tables must carry this store's application id. Only then does a read-write
    /// open switch to WAL and migrate, re-reading the version under the write lock because another
    /// connection may have migrated first. A read-only open accepts the current version and the older
    /// ones the schema reads without migrating, and leaves them as they are.
    static func open(file: URL, access: Access, schema: SQLiteLivingMemorySchema) throws -> SQLiteConnection {
        let path = file.path
        let flags: Int32
        switch access {
            case .readOnly:
                guard FileManager.default.fileExists(atPath: path) else {
                    throw SQLiteLivingMemoryError.missingStore(path: path)
                }
                flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            case .readWrite:
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        }
        let connection = try SQLiteConnection(path: path, flags: flags)
        try connection.execute("PRAGMA busy_timeout = \(busyTimeoutMilliseconds)")
        let found = try classify(connection, schema: schema)
        switch access {
            case .readOnly:
                // An older store this build reads as it is stays at its version: a reader never migrates.
                guard (schema.oldestReadableVersion...schema.currentVersion).contains(found) else {
                    throw SQLiteLivingMemoryError.needsMigration(path: path, found: found,
                                                                 current: schema.currentVersion)
                }
                try connection.execute("PRAGMA query_only = ON")
            case .readWrite:
                try connection.query("PRAGMA journal_mode = WAL")
                try connection.execute("""
                    PRAGMA synchronous = FULL;
                    PRAGMA fullfsync = ON;
                    PRAGMA checkpoint_fullfsync = ON;
                    PRAGMA foreign_keys = ON;
                    """)
                if found < schema.currentVersion { try migrate(connection, schema: schema) }
        }
        return connection
    }

    /// The store's schema version, after checking the file is a readable database that is empty or
    /// belongs to this store and is not newer than `schema`.
    private static func classify(_ connection: SQLiteConnection, schema: SQLiteLivingMemorySchema) throws -> Int {
        let path = connection.path
        let tables: Int64
        do {
            tables = try connection.integer("SELECT count(*) FROM sqlite_master") ?? 0
        } catch SQLiteLivingMemoryError.sqlite(let code, let message)
                    where code & 0xFF == SQLITE_NOTADB || code & 0xFF == SQLITE_CORRUPT {
            throw SQLiteLivingMemoryError.unreadable(path: path, message: message)
        }
        let application = try connection.integer("PRAGMA application_id") ?? 0
        let version = Int(try connection.integer("PRAGMA user_version") ?? 0)
        let isEmpty = tables == 0 && application == 0 && version == 0
        guard isEmpty || application == SQLiteLivingMemorySchema.applicationID else {
            throw SQLiteLivingMemoryError.notALivingMemoryStore(path: path)
        }
        guard version <= schema.currentVersion else {
            throw SQLiteLivingMemoryError.unsupportedSchemaVersion(path: path, found: version,
                                                                   supported: schema.currentVersion)
        }
        return version
    }

    /// Applies every migration newer than the stored version, and the new version, in one transaction.
    static func migrate(_ connection: SQLiteConnection, schema: SQLiteLivingMemorySchema) throws {
        try connection.transaction {
            let version = try classify(connection, schema: schema)
            guard version < schema.currentVersion else { return }
            for migration in schema.migrations where migration.version > version {
                try connection.execute(migration.statements)
            }
            try connection.execute("""
                PRAGMA application_id = \(SQLiteLivingMemorySchema.applicationID);
                PRAGMA user_version = \(schema.currentVersion);
                """)
        }
    }
}

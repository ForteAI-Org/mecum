//
//  SQLiteMemorySchema.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory

/// SQLiteMemorySchema is the DDL this module ships and what the bootstrap and the migration need to
/// know about it: the `user_version` the current schema carries, the text that creates it, the text
/// of each earlier schema it migrates from, and the tables they create. Schema 2 is the schema 1
/// resource, unchanged, followed by the schema 2 resource, which only adds: a new archive runs both,
/// and an archive at the exact shape of schema 1 runs the second one in its migration, so both end at
/// one shape. The texts carry no `PRAGMA`, `BEGIN` or `COMMIT` of their own; the store owns those
/// boundaries. Documentation/Engine/MemorySchema.md says what the resources are and how they differ
/// from the candidate they were copied from; Documentation/Engine/MemoryFacts.md what schema 2 adds.
enum SQLiteMemorySchema {

    /// The schema version this build bootstraps and opens. A file at version 0 with no tables is empty
    /// and is bootstrapped; a file at a version of `migrations` is migrated; any other is refused.
    static let version: Int32 = 2

    /// The resource of schema 1, the base every later schema adds to.
    static let resourceName      = "brain-living-memory-schema"
    static let resourceExtension = "sql"

    /// The resources each migration runs, by the version it migrates from: version 1 to 2 adds the
    /// tables of schema 2.
    static let migrations: [Int32: String] = [1: "brain-living-memory-schema-2"]

    /// The text that creates the current schema in an empty file: every resource, in order.
    static func text() throws -> String {
        try text(of: version)
    }

    /// The text that creates schema `version` in an empty file: the base and every migration below it.
    static func text(of version: Int32) throws -> String {
        var parts = [try resource(resourceName)]
        var from: Int32 = 1
        while from < version {
            parts.append(try migrationText(from: from))
            from += 1
        }
        return parts.joined(separator: "\n")
    }

    /// The text that migrates a file at `version` to the next one.
    static func migrationText(from version: Int32) throws -> String {
        guard let name = migrations[version] else {
            throw MemoryStoreError.unavailable(.resourceMissing("migration from \(version)"))
        }
        return try resource(name)
    }

    /// One resource's text, read from the module's bundle.
    private static func resource(_ name: String) throws -> String {
        let file = "\(name).\(resourceExtension)"
        guard let url = Bundle.module.url(forResource: name, withExtension: resourceExtension) else {
            throw MemoryStoreError.unavailable(.resourceMissing(file))
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MemoryStoreError.unavailable(.resourceMissing(file))
        }
    }

    /// Columns this build writes that an earlier development form of schema 1 did not have, as
    /// `(table, column)`. A file at version 1 or later with every table but without one of them is
    /// that earlier form: refused untouched, never migrated. The first distributed database carries them
    /// all; the list exists because files bootstrapped during development already exist at the same
    /// `user_version`. Table and column names are this module's own literals.
    static let requiredColumns: [(table: String, column: String)] = [
        ("brain_anchors", "current_group_id"),
        ("memory_operation_arguments", "brain_application_id"),
        ("memory_agent_actions", "started_at_ms"),
        // S3-d correction: a file the S3-d build created (42 tables, no duration, encoded effects) is
        // refused untouched by the table set and by these; nothing migrates or resets it.
        ("memory_agent_actions", "duration_ms"),
        ("memory_agent_actions", "observed_state_before"),
        ("memory_events", "origin_event_id"),
    ]

    /// SchemaObject is one table, index or trigger as `sqlite_schema` keeps it: its type, its name
    /// and the exact statement that created it.
    struct SchemaObject: Sendable, Equatable, Hashable {
        let type: String
        let name: String
        let sql : String?

        /// How a difference names it: `type name`.
        var label: String { "\(type) \(name)" }
    }

    /// The objects the text creates, read from a scratch database in memory that ran it: the exact
    /// shape a file bootstrapped by this build has. The library's own objects (`sqlite_%`) are left
    /// out on both sides.
    static func objects(of text: String) throws -> Set<SchemaObject> {
        let scratch = try SQLiteConnection(path: ":memory:")
        defer { scratch.close() }
        try scratch.execute(text)
        return try objects(in: scratch)
    }

    /// The objects a database holds, the library's own left out.
    static func objects(in connection: SQLiteConnection) throws -> Set<SchemaObject> {
        Set(try connection.query(
            "SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'"
        ) { SchemaObject(type: try $0.text(0) ?? "", name: try $0.text(1) ?? "", sql: try $0.text(2)) })
    }

    /// The objects that differ between a file and the expected shape, missing, extra or written
    /// differently, as sorted labels; empty when the file is exactly the expected shape.
    static func differences(found: Set<SchemaObject>, expected: Set<SchemaObject>) -> [String] {
        Set(found.symmetricDifference(expected).map(\.label)).sorted()
    }

    /// Every table the text creates, in creation order, read from its `CREATE TABLE` lines.
    static func tableNames(in text: String) -> [String] {
        let prefix = "CREATE TABLE "
        return text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
    }
}

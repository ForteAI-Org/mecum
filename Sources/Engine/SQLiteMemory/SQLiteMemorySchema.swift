//
//  SQLiteMemorySchema.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory

/// SQLiteMemorySchema is the one DDL resource this module ships and what the bootstrap needs to know
/// about it: the `user_version` a bootstrapped file carries, the tables the text creates, and the
/// text itself. The text carries no `PRAGMA`, `BEGIN` or `COMMIT` of its own; the store owns those
/// boundaries. Documentation/Engine/MemorySchema.md says what the resource is and how it differs
/// from the candidate it was copied from.
enum SQLiteMemorySchema {

    /// The schema version this resource produces. A file at version 0 with no tables is empty and
    /// is bootstrapped; any other version is refused.
    static let version: Int32 = 1

    static let resourceName      = "brain-living-memory-schema"
    static let resourceExtension = "sql"

    /// The DDL text, read from the module's resource bundle. The bootstrap runs it once per open.
    static func text() throws -> String {
        let name = "\(resourceName).\(resourceExtension)"
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw MemoryStoreError.unavailable(.resourceMissing(name))
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MemoryStoreError.unavailable(.resourceMissing(name))
        }
    }

    /// Columns this build writes that an earlier development form of schema 1 did not have, as
    /// `(table, column)`. A file at version 1 with every table but without one of them is that
    /// earlier form: refused untouched, never migrated. The first distributed database carries them
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

    /// Every table the text creates, in creation order, read from its `CREATE TABLE` lines.
    static func tableNames(in text: String) -> [String] {
        let prefix = "CREATE TABLE "
        return text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
    }
}

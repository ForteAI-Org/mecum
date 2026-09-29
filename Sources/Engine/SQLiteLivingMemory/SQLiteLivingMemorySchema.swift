//
//  SQLiteLivingMemorySchema.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

/// SQLiteLivingMemorySchema is the store's versioned schema: an ordered list of migrations, each
/// taking the database from the previous version to its own. Version 0 is an empty file.
///
/// A migration runs inside the same transaction that sets `user_version`, so a store is at one
/// version or the next, never between. Migrations are never edited once released: a change is a
/// new migration. Rows hold the Memory record as JSON beside the key columns the queries need, so a
/// record shape an older build cannot decode is a new version too, even when no table changes: the
/// older build then refuses the file at open instead of failing on one row.
struct SQLiteLivingMemorySchema: Sendable {

    /// Migration is one schema step.
    struct Migration: Sendable {
        let version: Int
        let statements: String

        /// Whether this build reads a store at the previous version as it is: the step changes no
        /// table or column, only what new rows may hold, and every older row still decodes.
        let readsPreviousVersion: Bool

        init(version: Int, statements: String, readsPreviousVersion: Bool = false) {
            self.version              = version
            self.statements           = statements
            self.readsPreviousVersion = readsPreviousVersion
        }
    }

    /// Marks a database as a Mecum living memory store in its header ("MLMS").
    static let applicationID: Int64 = 0x4D4C_4D53

    let migrations: [Migration]

    var currentVersion: Int { migrations.last?.version ?? 0 }

    /// The oldest version a read-only open accepts without migrating: the current one, and every
    /// earlier one reached only through migrations that read their previous version.
    var oldestReadableVersion: Int {
        var version = currentVersion
        for migration in migrations.reversed() where migration.version == version && migration.readsPreviousVersion {
            version -= 1
        }
        return version
    }

    static let current = SQLiteLivingMemorySchema(migrations: [
        Migration(version: 1, statements: """
            CREATE TABLE sightings (
                bundle_id     TEXT NOT NULL,
                window_family TEXT NOT NULL,
                identity_key  TEXT NOT NULL,
                record        TEXT NOT NULL,
                PRIMARY KEY (bundle_id, window_family, identity_key)
            ) WITHOUT ROWID;
            CREATE TABLE experiences (
                id          TEXT PRIMARY KEY,
                natural_key TEXT NOT NULL UNIQUE,
                bundle_id   TEXT NOT NULL,
                record      TEXT NOT NULL
            );
            CREATE INDEX experiences_by_bundle ON experiences (bundle_id);
            CREATE TABLE experience_events (
                sequence      INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id      TEXT NOT NULL UNIQUE,
                experience_id TEXT REFERENCES experiences (id),
                entry         TEXT NOT NULL
            );
            CREATE INDEX experience_events_by_experience ON experience_events (experience_id);
            CREATE TABLE recall_decisions (
                sequence      INTEGER PRIMARY KEY AUTOINCREMENT,
                decision_id   TEXT NOT NULL UNIQUE,
                experience_id TEXT,
                record        TEXT NOT NULL
            );
            CREATE INDEX recall_decisions_by_experience ON recall_decisions (experience_id);
            """),
        // Experiences and events may hold set_toggle and click steps and their evidence. Version 1 rows
        // decode unchanged, and a select is still written in the version 1 shape.
        Migration(version: 2, statements: """
            -- No table changes: version 2 marks the toggle and click record shapes.
            """, readsPreviousVersion: true),
    ])
}

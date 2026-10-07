//
//  MemorySchemaMismatch.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// MemorySchemaMismatch describes an archive whose schema this build refuses to touch. Every case
/// leaves the file exactly as it was found: an archive is never reset, repaired or downgraded.
public enum MemorySchemaMismatch: Sendable, Equatable {

    /// The archive was written by a newer build: its version is above the one this build knows.
    case future(found: Int32, supported: Int32)

    /// A version 0 file already holds tables this schema did not create: somebody else's database.
    case unknownTables([String])

    /// A file at the supported version lacks tables the schema defines.
    case missingTables([String])

    /// A file at the supported version has every table but lacks columns this build writes, named
    /// `table.column`: an earlier development form of the same schema version, never a distributed
    /// one. It is refused as found; no migration runs on the store's own initiative.
    case missingColumns([String])

    /// A file at the supported version has every table and column but its schema is not the one
    /// this build creates: a table, index or trigger is missing, extra or written differently,
    /// named `type name`. Constraints are part of the shape, so an earlier development form whose
    /// columns match but whose checks do not is refused here, before a write could fail on them.
    case differentShape([String])

    /// A file with no schema of its own yet (version 0, no table): what a producer's open bootstraps,
    /// and what an open of an existing archive refuses, untouched. `fileIsEmpty` is a file of zero
    /// bytes, with no SQLite header at all; false is a SQLite database with nothing in it.
    case uninitialized(fileIsEmpty: Bool)
}

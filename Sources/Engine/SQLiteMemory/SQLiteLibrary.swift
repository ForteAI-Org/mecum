//
//  SQLiteLibrary.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import SQLite3

/// SQLiteLibrary reports the SQLite the running binary is linked against and checks it against what
/// the schema needs. The `sqlite3` command and Python's module say nothing about this library:
/// only these answers, read from the linked image, do.
public enum SQLiteLibrary {

    /// The linked library's version, as `sqlite3_libversion()` reports it.
    public static var version: String { String(cString: sqlite3_libversion()) }

    /// The linked library's source identifier: date, time and check-in hash of its build.
    public static var sourceID: String { String(cString: sqlite3_sourceid()) }

    /// The version as one integer: `3054000` for 3.54.0.
    public static var versionNumber: Int32 { sqlite3_libversion_number() }

    /// Requirement is one thing the schema or the store needs from the library.
    public enum Requirement: Sendable, Equatable, CaseIterable {

        /// `STRICT` tables, which every table of the schema declares.
        case strictTables

        /// The concurrent-WAL correction the store relies on: 3.51.3, or its backports 3.44.6
        /// and 3.50.7 within their own minor lines.
        case concurrentWAL

        /// The oldest version that satisfies the requirement, for a message.
        public var minimumVersion: String {
            switch self {
            case .strictTables : "3.37.0"
            case .concurrentWAL: "3.51.3 (or 3.44.6, 3.50.7)"
            }
        }

        /// Whether a library at this version number satisfies the requirement.
        public func isSatisfied(by number: Int32) -> Bool {
            switch self {
            case .strictTables:
                number >= 3_037_000
            case .concurrentWAL:
                number >= 3_051_003
                    || (number >= 3_044_006 && number < 3_045_000)
                    || (number >= 3_050_007 && number < 3_051_000)
            }
        }
    }

    /// The first requirement the library at `number` does not meet, or nil when it meets all.
    public static func unmetRequirement(of number: Int32 = versionNumber) -> Requirement? {
        Requirement.allCases.first { !$0.isSatisfied(by: number) }
    }
}

//
//  SQLiteMenuCommandRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory

/// SQLiteMenuCommandRepository is `MenuCommandStoring` over `SQLiteMemoryStore`: a command in
/// `brain_menu_commands`, its path as ordered rows of `brain_menu_path_segments` at positions
/// 0 ..< n, in one write transaction with its application found or created. `path_key` is written as
/// the joined path, a search hint behind the `brain_menu_by_path_hint` index; it is neither unique
/// nor an identity. Nothing in production calls it yet, and it never touches the brain's projection.
public struct SQLiteMenuCommandRepository: MenuCommandStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ command: MenuCommandRecord) async throws -> MemoryReceipt {
        try await store.write { transaction in
            if let stored = try SQLiteMenuRows.read(transaction, menuCommandID: command.menuCommandID) {
                guard stored.isExactly(command) else { throw SQLiteMenuRows.conflict(stored: stored, offered: command) }
                return .alreadyApplied
            }
            let appID = try SQLiteIdentityRows.ensureApp(transaction, bundleID: command.bundleID)
            try SQLiteMenuRows.insert(transaction, command, appID: appID)
            return .committed
        }
    }

    public func update(from expected: MenuCommandRecord, to updated: MenuCommandRecord) async throws -> MemoryReceipt {
        let id = expected.menuCommandID
        guard expected.sameIdentity(as: updated) else {
            let field = !expected.menuCommandID.utf8.elementsEqual(updated.menuCommandID.utf8) ? "menu_command_id"
                : !expected.bundleID.utf8.elementsEqual(updated.bundleID.utf8) ? "app"
                : expected.firstSeenMS != updated.firstSeenMS ? "first_seen_ms" : "path"
            throw MenuCommandError.immutableField(menuCommandID: id, field: field)
        }
        guard updated.lastSeenMS >= expected.lastSeenMS else { throw MenuCommandError.lastSeenBackwards(menuCommandID: id) }
        return try await store.write { transaction in
            guard let stored = try SQLiteMenuRows.read(transaction, menuCommandID: id) else {
                throw MenuCommandError.missingCommand(menuCommandID: id)
            }
            if stored.isExactly(updated) { return .alreadyApplied }
            guard stored.isExactly(expected) else { throw MenuCommandError.staleExpectation(menuCommandID: id) }
            try transaction.execute(
                """
                UPDATE brain_menu_commands SET top_level_title = ?, accessibility_identifier = ?, has_submenu = ?,
                    last_observed_enabled = ?, mark_char = ?, cmd_char = ?, last_seen_ms = ?
                WHERE menu_command_id = ?
                """,
                [.text(updated.topLevelTitle), updated.identifier.map(SQLiteValue.text) ?? .null, .integer(updated.hasSubmenu ? 1 : 0),
                 .integer(updated.enabled ? 1 : 0), updated.markChar.map(SQLiteValue.text) ?? .null,
                 updated.cmdChar.map(SQLiteValue.text) ?? .null, .integer(updated.lastSeenMS), .text(id)]
            )
            return .committed
        }
    }

    public func menuCommand(_ menuCommandID: String) async throws -> MenuCommandRecord? {
        try await store.read { snapshot in try SQLiteMenuRows.read(snapshot, menuCommandID: menuCommandID) }
    }

    public func menuCommands(of bundleID: String, pathKey: String?) async throws -> [MenuCommandRecord] {
        try await store.read { snapshot in
            guard let appID = try SQLiteIdentityRows.appID(snapshot, bundleID: bundleID) else { return [] }
            var sql = "SELECT menu_command_id FROM brain_menu_commands WHERE app_id = ?"
            var bindings: [SQLiteValue] = [.integer(appID)]
            if let pathKey {
                sql += " AND path_key = ?"
                bindings.append(.text(pathKey))
            }
            let ids = try snapshot.query(sql + " ORDER BY menu_command_id", bindings) { try $0.text(0) ?? "" }
            let records = try ids.compactMap { try SQLiteMenuRows.read(snapshot, menuCommandID: $0) }
            return records.sorted { lhs, rhs in
                let left = lhs.path.map { Array($0.utf8) }, right = rhs.path.map { Array($0.utf8) }
                if left != right { return left.lexicographicallyPrecedes(right) { $0.lexicographicallyPrecedes($1) } }
                return Array(lhs.menuCommandID.utf8).lexicographicallyPrecedes(Array(rhs.menuCommandID.utf8))
            }
        }
    }
}

/// SQLiteMenuRows is the codec of a command and its path segments, inside the caller's handle.
enum SQLiteMenuRows {

    static func insert(_ transaction: SQLiteTransaction, _ command: MenuCommandRecord, appID: Int64) throws {
        try transaction.execute(
            """
            INSERT INTO brain_menu_commands (menu_command_id, app_id, path_key, top_level_title, accessibility_identifier,
                has_submenu, last_observed_enabled, mark_char, cmd_char, first_seen_ms, last_seen_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(command.menuCommandID), .integer(appID), .text(command.pathKey), .text(command.topLevelTitle),
             command.identifier.map(SQLiteValue.text) ?? .null, .integer(command.hasSubmenu ? 1 : 0),
             .integer(command.enabled ? 1 : 0), command.markChar.map(SQLiteValue.text) ?? .null,
             command.cmdChar.map(SQLiteValue.text) ?? .null, .integer(command.firstSeenMS), .integer(command.lastSeenMS)]
        )
        for (position, title) in command.path.enumerated() {
            try transaction.execute(
                "INSERT INTO brain_menu_path_segments (menu_command_id, position, title) VALUES (?, ?, ?)",
                [.text(command.menuCommandID), .integer(Int64(position)), .text(title)]
            )
        }
    }

    /// The stored command, or nil, refusing a command with no segment, segments that are not the
    /// positions 0 ..< n, a `path_key` that is not its joined path, or a sighting outside the
    /// clock's range or out of order. Texts are read strictly; the flags are the schema's 0 and 1.
    static func read(_ handle: some SQLiteQuerying, menuCommandID: String) throws -> MenuCommandRecord? {
        guard let row = try handle.query(
            """
            SELECT m.menu_command_id, a.bundle_id, m.path_key, m.top_level_title, m.accessibility_identifier, m.has_submenu,
                   m.last_observed_enabled, m.mark_char, m.cmd_char, m.first_seen_ms, m.last_seen_ms
            FROM brain_menu_commands m JOIN brain_apps a ON a.app_id = m.app_id
            WHERE m.menu_command_id = ?
            """,
            [.text(menuCommandID)],
            { row in
                (id: try row.text(0) ?? "", bundle: try row.text(1) ?? "", pathKey: try row.text(2) ?? "", title: try row.text(3) ?? "",
                 identifier: try row.text(4), submenu: row.integer(5) == 1, enabled: row.integer(6) == 1, mark: try row.text(7),
                 shortcut: try row.text(8), first: row.integer(9) ?? 0, last: row.integer(10) ?? 0)
            }
        ).first else { return nil }
        func refuse(_ malformation: MenuCommandError.Malformation) -> MenuCommandError {
            .malformedRow(menuCommandID: menuCommandID, malformation: malformation)
        }
        let segments = try handle.query(
            "SELECT position, title FROM brain_menu_path_segments WHERE menu_command_id = ? ORDER BY position",
            [.text(menuCommandID)]
        ) { (position: $0.integer(0) ?? -1, title: try $0.text(1) ?? "") }
        guard !segments.isEmpty else { throw refuse(.noSegments) }
        guard segments.enumerated().allSatisfy({ Int64($0.offset) == $0.element.position }) else { throw refuse(.segmentsNotContiguous) }
        let path = segments.map(\.title)
        guard path.joined(separator: "/").utf8.elementsEqual(row.pathKey.utf8) else { throw refuse(.pathKeyMismatch) }
        for instant in [row.first, row.last] where !BrainClock.range.contains(instant) { throw refuse(.millisecondsOutOfRange(instant)) }
        guard row.last >= row.first else { throw refuse(.lastSeenBeforeFirst) }
        return try MenuCommandRecord(
            menuCommandID: row.id, bundleID: row.bundle, path: path, topLevelTitle: row.title, identifier: row.identifier,
            hasSubmenu: row.submenu, enabled: row.enabled, markChar: row.mark, cmdChar: row.shortcut,
            firstSeenMS: row.first, lastSeenMS: row.last
        )
    }

    static func conflict(stored: MenuCommandRecord, offered: MenuCommandRecord) -> MemoryStoreError {
        func digest(_ record: MenuCommandRecord) -> String {
            StructuralDigest.fnv1a(([record.bundleID, record.topLevelTitle, record.identifier ?? "\u{0}nil",
                                     record.markChar ?? "\u{0}nil", record.cmdChar ?? "\u{0}nil",
                                     "\(record.hasSubmenu)", "\(record.enabled)", "\(record.firstSeenMS)", "\(record.lastSeenMS)"]
                                    + record.path).joined(separator: "\u{1E}"))
        }
        return .identity(MemoryIdentityConflict(identity: offered.menuCommandID, storedFingerprint: digest(stored),
                                                offeredFingerprint: digest(offered)))
    }
}

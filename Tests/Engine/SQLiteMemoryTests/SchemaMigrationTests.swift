//
//  SchemaMigrationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// SchemaMigrationTests prove the move from schema 1 to schema 2 on real files: an archive of schema 1
/// with facts in it migrates on a producer's open, after a verified copy, keeping every row; a reader
/// never migrates; a migration that fails leaves schema 1 as it was; two openers migrate once.
@Suite("Migrating an archive of schema 1 to schema 2")
struct SchemaMigrationTests {

    /// The tables of schema 1, whose rows a migration must keep.
    static func version1Tables() throws -> [String] {
        SQLiteMemorySchema.tableNames(in: try SQLiteMemorySchema.text(of: 1))
    }

    /// An archive of schema 1 holding facts: written through this build's repositories, then the
    /// tables schema 2 added are dropped and the version set back, which leaves exactly the shape a
    /// schema 1 build bootstraps (no table of schema 1 is altered by schema 2).
    static func populatedVersion1() async throws -> URL {
        let memory = try await AgentCallFixtures.open()
        let call = try AgentCallFixtures.call("a1", .act(target: "Save", verb: .click, value: nil, section: nil))
        #expect(try await memory.calls.record(call) == .committed)
        _ = try await memory.calls.advance([AgentCallTransition("a1", .started(atMS: AgentCallFixtures.t0))])
        _ = try await memory.calls.advance([AgentCallTransition("a1", AgentCallProgress(
            .completed, result: .outcome(.foundActed, message: "clicked 'Save'"), endedAtMS: AgentCallFixtures.t0 + 5
        ))])
        let window = SceneFixtures.pixelsOnly(["Save", "Open"])
        _ = try await memory.captures.record(SceneFixtures.event("o1"))
        _ = try await memory.captures.record(SceneFixtures.sample("o1", of: window))
        await memory.store.close()
        try downgrade(memory.url)
        return memory.url
    }

    /// Drops the tables schema 2 added and sets version 1: their indexes and triggers go with them.
    static func downgrade(_ url: URL) throws {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        for table in SQLiteMemorySchema.tableNames(in: try SQLiteMemorySchema.migrationText(from: 1)).reversed() {
            try raw.execute("DROP TABLE \(table)")
        }
        try raw.execute("PRAGMA user_version = 1")
    }

    static func counts(_ tables: [String], at url: URL) throws -> [String: Int64] {
        var counts: [String: Int64] = [:]
        for table in tables { counts[table] = try rawCount("SELECT count(*) FROM \(table)", at: url) }
        return counts
    }

    @Test("an archive of schema 1 with facts is migrated by a producer's open, after a verified copy beside it, keeping every row")
    func migratesKeepingRows() async throws {
        let url    = try await Self.populatedVersion1()
        let tables = try Self.version1Tables()
        let before = try Self.counts(tables, at: url)
        #expect(before["memory_events"] == 2 && before["memory_agent_actions"] == 1
                && before["memory_event_observations"]! > 0)
        #expect(SQLiteMemoryInspection.inspect(url).shape == .migratable(from: 1))

        let store = try await SQLiteMemoryStore.open(at: url)
        let diagnostics = try await store.diagnostics()
        let migration = try #require(diagnostics.migration)
        #expect(migration.fromVersion == 1 && migration.toVersion == 2)
        #expect(diagnostics.schemaVersion == 2 && !diagnostics.bootstrappedNow)
        #expect(try await store.read { try SchemaShape($0) } == SchemaShape.current)
        let recorded = try await store.read { snapshot in
            try snapshot.query("SELECT to_version, from_version, copy_name FROM memory_schema_migrations") {
                ($0.integer(0) ?? 0, $0.integer(1) ?? 0, try $0.text(2) ?? "")
            }
        }
        #expect(recorded.count == 1 && recorded[0].0 == 2 && recorded[0].1 == 1 && recorded[0].2 == migration.copyName)
        let call = try #require(try await SQLiteAgentCallRepository(store: store).call("a1"))
        #expect(call.progress.status == .completed)
        await store.close()
        #expect(try Self.counts(tables, at: url) == before, "every row of schema 1 is kept")

        let copy = url.deletingLastPathComponent().appendingPathComponent(migration.copyName)
        #expect(SQLiteMemoryInspection.inspect(copy).shape == .migratable(from: 1),
                "the copy is the archive of schema 1 as it was")
        #expect(try Self.counts(tables, at: copy) == before)
        let check = try SQLiteConnection(path: copy.path, readOnly: true)
        #expect(try check.query("PRAGMA integrity_check") { try $0.text(0) }.first == "ok")
        #expect(try check.query("PRAGMA journal_mode") { try $0.text(0) }.first == "delete")
        check.close()

        let again = try await SQLiteMemoryStore.open(at: url)
        #expect(try await again.diagnostics().migration == nil, "an archive migrated once is opened as it is")
        await again.close()
        #expect(try strayFiles(beside: url).filter { $0.contains(".schema-1-") && !$0.hasSuffix(".lock") }
                == [migration.copyName])
    }

    @Test("a reader never migrates: an archive of schema 1 is refused to it, untouched")
    func readerRefuses() async throws {
        let url    = try await Self.populatedVersion1()
        let before = try Self.counts(try Self.version1Tables(), at: url)
        let store  = SQLiteMemoryStore(url: url)
        let error  = await storeError { try await store.open(.existingArchive) }
        #expect(error == .schema(.migrationRequired(found: 1, supported: 2)))
        #expect(try rawCount("PRAGMA user_version", at: url) == 1)
        #expect(try Self.counts(try Self.version1Tables(), at: url) == before)
        #expect(try strayFiles(beside: url).allSatisfy { !$0.contains(".schema-1-") }, "no copy either")
    }

    @Test("a migration that fails inside its transaction leaves schema 1 whole, keeps the copy, and the next open migrates")
    func failedMigrationRollsBack() async throws {
        struct Fault: Error {}
        let url    = try await Self.populatedVersion1()
        let tables = try Self.version1Tables()
        let before = try Self.counts(tables, at: url)
        let store  = SQLiteMemoryStore(url: url)
        await store.injectMigrationFault { throw Fault() }
        await #expect(throws: (any Error).self) { try await store.open() }
        #expect(try rawCount("PRAGMA user_version", at: url) == 1)
        #expect(SQLiteMemoryInspection.inspect(url).shape == .migratable(from: 1),
                "exactly schema 1, nothing of schema 2 left")
        #expect(try Self.counts(tables, at: url) == before)
        #expect(try strayFiles(beside: url).filter { $0.contains(".schema-1-") && !$0.hasSuffix(".lock") }.count == 1,
                "the verified copy stays")

        let retried = try await SQLiteMemoryStore.open(at: url)
        #expect(try await retried.diagnostics().migration?.fromVersion == 1)
        #expect(try await retried.read { try SchemaShape($0) } == SchemaShape.current)
        await retried.close()
        #expect(try Self.counts(tables, at: url) == before)
    }

    @Test("two opens of one archive of schema 1 at once migrate it once; the second finds schema 2 and keeps no copy of its own")
    func twoOpenersMigrateOnce() async throws {
        let url = try await Self.populatedVersion1()
        async let first  = SQLiteMemoryStore.open(at: url)
        async let second = SQLiteMemoryStore.open(at: url)
        let (a, b) = try await (first, second)
        let migrations = [try await a.diagnostics().migration, try await b.diagnostics().migration].compactMap { $0 }
        #expect(migrations.count == 1)
        #expect(try await a.read { try SchemaShape($0) } == SchemaShape.current)
        await a.close()
        await b.close()
        #expect(try strayFiles(beside: url).filter { $0.contains(".schema-1-") && !$0.hasSuffix(".lock") }
                == migrations.map(\.copyName))
        #expect(try rawCount("SELECT count(*) FROM memory_schema_migrations", at: url) == 1)
    }

    @Test("a new archive records its bootstrap at schema 2 from nothing, with no copy")
    func bootstrapRecorded() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(try await store.diagnostics().bootstrappedNow)
        let row = try await store.read { snapshot in
            try snapshot.query("SELECT to_version, from_version, copy_name IS NULL FROM memory_schema_migrations") {
                ($0.integer(0) ?? 0, $0.integer(1) ?? 0, $0.integer(2) ?? 0)
            }
        }
        #expect(row.count == 1 && row[0] == (2, 0, 1))
        await store.close()
    }

    @Test("a schema 1 file restored from a copy by a recovery is a sound copy: the next open migrates it again")
    func olderCopyIsSound() async throws {
        let url  = try await Self.populatedVersion1()
        let copy = url.deletingLastPathComponent().appendingPathComponent("memory.sqlite.backup-2026-10-09T000000.000Z")
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("VACUUM INTO '\(copy.path)'")
        raw.close()
        // A copy whose header still says WAL cannot be opened read only without its log files beside it.
        let settled = try SQLiteConnection(path: copy.path)
        _ = try settled.query("PRAGMA journal_mode = DELETE") { try $0.text(0) }
        settled.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try Data(repeating: 0x5A, count: 8192).write(to: url)
        let outcome = try SQLiteMemoryRecovery.recover(url, copies: { [copy] }, stamp: "migrating")
        guard case .recovered(_, let restored?) = outcome else { Issue.record("not recovered: \(outcome)"); return }
        #expect(restored == copy.lastPathComponent)
        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(try await store.diagnostics().migration?.fromVersion == 1)
        #expect(try await count("SELECT count(*) FROM memory_agent_actions", in: store) == 1)
        await store.close()
    }
}

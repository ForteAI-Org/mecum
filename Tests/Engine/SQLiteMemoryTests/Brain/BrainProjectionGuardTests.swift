//
//  BrainProjectionGuardTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// What the brain's projection refuses, and what it keeps whole: two stores on one file, a mutation
/// rolled back by the file or by its own contract, an earlier form of schema 1, the foreign key of
/// the current group, rows another hand wrote, a clock that runs backwards.
@Suite("The brain's projection refuses what it cannot keep")
struct BrainProjectionGuardTests {

    private typealias F = BrainFixtures

    private func det(_ kind: ElementKind, _ label: String, x: Double, y: Double,
                     w: Double = 0.03, h: Double = 0.017, state: ControlState? = nil) -> BrainDetection {
        F.det(kind, label, x: x, y: y, w: w, h: h, state: state)
    }

    /// A store with random identities, for two writers on one file.
    private func openRandom(at url: URL? = nil) async throws -> (store: SQLiteMemoryStore, brain: SQLiteBrainRepository, url: URL) {
        let url   = try url ?? temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return (store, SQLiteBrainRepository(store: store), url)
    }

    @Test("two stores on one file mutate the same counter and different anchors concurrently without losing an update, and each sees the other's commit")
    func concurrentStores() async throws {
        let one = try await openRandom()
        let two = try await openRandom(at: one.url)
        let scene = F.scene(["A", "B", "C"])
        _ = try await one.brain.ingest(scene, into: F.bundle, now: F.t0, window: nil)
        async let first  = one.brain.ingest(scene, into: F.bundle, now: F.t1, window: nil)
        async let second = two.brain.ingest(scene, into: F.bundle, now: F.t1, window: nil)
        async let third  = one.brain.ingest([det(.control, "Only one", x: 0.8, y: 0.1)], into: F.bundle, now: F.t1, window: nil)
        async let fourth = two.brain.ingest([det(.control, "Only two", x: 0.8, y: 0.3)], into: F.bundle, now: F.t1, window: nil)
        let stats = try await [first, second, third, fourth]
        #expect(stats[0].updated == 3 && stats[1].updated == 3 && stats[2].created == 1 && stats[3].created == 1)
        let fromOne = try #require(try await one.brain.brain(of: F.bundle))
        let fromTwo = try #require(try await two.brain.brain(of: F.bundle))
        #expect(fromOne == fromTwo)
        #expect(fromOne.objects.filter { ["A", "B", "C"].contains($0.label) }.map(\.seenCount) == [3, 3, 3])
        #expect(Set(fromOne.objects.map(\.label)) == ["A", "B", "C", "Only one", "Only two"])
        #expect(try await count("SELECT count(*) FROM brain_anchors", in: two.store) == 5)
        #expect(try await one.store.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await one.store.close()
        await two.store.close()
    }

    @Test("a mutation the file refuses rolls back whole, the application row included, and the store stays usable for the same mutation")
    func rollbackOnFullDatabase() async throws {
        let memory = try await F.open()
        let pages = try await memory.store.read { try $0.query("PRAGMA page_count") { $0.integer(0) ?? 0 }.first ?? 0 }
        _ = try await memory.store.write { transaction in
            // A pragma takes no bound value; the number is the file's own page count plus one.
            try transaction.execute("PRAGMA max_page_count = \(pages + 1)")
        }
        let padding = String(repeating: "x", count: 40)
        let many = (0..<300).map { det(.control, "Control \($0) \(padding)", x: 0.1, y: Double($0) * 0.003) }
        let error = await storeError { _ = try await memory.brain.ingest(many, into: F.bundle, now: F.t0, window: nil) }
        guard case .failed(let fault)? = error else {
            Issue.record("expected the file to refuse, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 13)
        #expect(try await memory.load() == nil, "the application row was part of the same transaction")
        #expect(try await memory.integers("SELECT count(*) FROM brain_anchors") == [0])
        _ = try await memory.store.write { try $0.execute("PRAGMA max_page_count = 1073741823") }
        let stats = try await memory.brain.ingest(many, into: F.bundle, now: F.t0, window: nil)
        #expect(stats.created == 300)
        #expect(try await memory.load()?.objects.count == 300)
        await memory.store.close()
    }

    @Test("a schema 1 file of the earlier form, without the current group column, is refused by name and left untouched")
    func oldFormRefused() async throws {
        let url = try temporaryDatabase()
        let ddl = try SQLiteMemorySchema.text()
        let old = ddl
            .replacingOccurrences(of: "    current_group_id TEXT,\n", with: "")
            .replacingOccurrences(of: "    FOREIGN KEY (app_id, current_group_id) REFERENCES brain_groups(app_id, group_id),\n", with: "")
        #expect(old != ddl && !old.contains("current_group_id TEXT") && !old.contains("FOREIGN KEY (app_id, current_group_id)"))
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("PRAGMA foreign_keys = ON")
        try raw.execute(old)
        try raw.execute("PRAGMA user_version = 1")
        raw.close()
        let before = try Data(contentsOf: url)

        let error = await storeError { _ = try await SQLiteMemoryStore.open(at: url) }
        #expect(error == .schema(.missingColumns(["brain_anchors.current_group_id"])))
        #expect(try Data(contentsOf: url) == before)
        let check = try SQLiteConnection(path: url.path)
        #expect(try check.query("PRAGMA user_version") { $0.integer(0) }.first == 1)
        #expect(try check.query("PRAGMA journal_mode") { try $0.text(0) }.first == "delete")
        #expect(try check.query("SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") { $0.integer(0) }.first == 48)
        check.close()

        let fresh = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let columns = try await fresh.read { try $0.query("PRAGMA table_info(brain_anchors)") { try $0.text(1) ?? "" } }
        #expect(columns.contains("current_group_id"))
        #expect(try await fresh.read { try SchemaShape($0) } == SchemaShape(tables: 48, triggers: 48, indexes: 31))
        let foreignKeys = try await fresh.read { snapshot in
            try snapshot.query("PRAGMA foreign_key_list(brain_anchors)") { row in (try row.text(2) ?? "", try row.text(3) ?? "", try row.text(4) ?? "") }
        }
        #expect(foreignKeys.contains { $0 == ("brain_groups", "current_group_id", "group_id") })
        await fresh.close()
    }

    @Test("the current group is a foreign key per application: the same application's group is accepted, a missing or another application's group is refused, a retired group stays referenceable")
    func currentGroupForeignKey() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        try await store.write { transaction in
            try transaction.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (1, 'a'), (2, 'b')")
            try transaction.execute(
                """
                INSERT INTO brain_groups (group_id, app_id, insertion_order, axis, shared_kind, cell_width, cell_height, last_seen_ms)
                VALUES ('g1', 1, 0, 'column', 'control', 0.03, 0.017, 100), ('g2', 2, 0, 'row', 'control', 0.03, 0.017, 100)
                """
            )
            try transaction.execute(
                """
                INSERT INTO brain_anchors (anchor_id, app_id, insertion_order, kind, label, first_seen_ms, last_seen_ms, current_group_id)
                VALUES ('a1', 1, 0, 'control', 'Send', 0, 100, 'g1')
                """
            )
        }
        let missing = await refusal(of: "UPDATE brain_anchors SET current_group_id = 'nowhere' WHERE anchor_id = 'a1'", in: store)
        #expect(missing?.code.extended == 787)
        let crossApp = await refusal(of: "UPDATE brain_anchors SET current_group_id = 'g2' WHERE anchor_id = 'a1'", in: store)
        #expect(crossApp?.code.extended == 787)
        #expect(await refusal(of: """
            INSERT INTO brain_anchors (anchor_id, app_id, insertion_order, kind, label, first_seen_ms, last_seen_ms, current_group_id)
            VALUES ('a2', 2, 0, 'control', 'Send', 0, 100, 'g1')
            """, in: store) != nil)
        try await store.write { transaction in
            try transaction.execute("UPDATE brain_anchors SET current_group_id = NULL WHERE anchor_id = 'a1'")
            try transaction.execute("UPDATE brain_anchors SET current_group_id = 'g1' WHERE anchor_id = 'a1'")
            try transaction.execute("UPDATE brain_groups SET retired_at_ms = 200, retired_epoch = 1, retirement_cause = 'members' WHERE group_id = 'g1'")
        }
        #expect(try await store.read { try $0.query("SELECT current_group_id FROM brain_anchors") { try $0.text(0) } } == ["g1"])
        #expect(try await store.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await store.close()
    }

    @Test("a clock that runs backwards is refused by the file's own check, the mutation is rolled back and the store goes on")
    func backwardsClockRefused() async throws {
        let twin = try await F.Twin()
        try await twin.ingest([det(.control, "X", x: 0.1, y: 0.1)], at: F.t1)
        let error = await storeError { _ = try await twin.memory.brain.ingest([det(.control, "X", x: 0.1, y: 0.1)], into: F.bundle, now: F.t0, window: nil) }
        guard case .contract(let fault)? = error else {
            Issue.record("expected a contract refusal, got \(String(describing: error))")
            return
        }
        #expect(fault.message.contains("CHECK"))
        try await twin.check()
        #expect(twin.reference.objects[0].seenCount == 1)
        try await twin.ingest([det(.control, "X", x: 0.1, y: 0.1)], at: try F.clock(200))
        #expect(twin.reference.objects[0].seenCount == 2)
        await twin.close()
    }
}

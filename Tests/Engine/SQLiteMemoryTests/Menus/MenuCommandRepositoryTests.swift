//
//  MenuCommandRepositoryTests.swift
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

/// The menu repository: a command and its ordered path written whole, read back field for field
/// after reopening, recorded once by its id, changed only by an explicit update against the record
/// last read, refused on rows it cannot read, and kept beside the brain's projection without being it.
@Suite("The menu command repository", .serialized)
struct MenuCommandRepositoryTests {

    private static let bundle = "test.fixture.menus"

    private struct Memory {
        let url: URL
        let store: SQLiteMemoryStore
        let menus: SQLiteMenuCommandRepository

        func count(_ sql: String) async throws -> Int64 {
            try await store.read { try $0.query(sql, []) { $0.integer(0) ?? -1 }.first ?? -1 }
        }

        func ledger() async throws -> [Int64] {
            [try await count("SELECT count(*) FROM brain_menu_commands"), try await count("SELECT count(*) FROM brain_menu_path_segments"),
             try await count("SELECT count(*) FROM brain_apps")]
        }
    }

    private static func open(at url: URL? = nil) async throws -> Memory {
        let url = try url ?? temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return Memory(url: url, store: store, menus: SQLiteMenuCommandRepository(store: store))
    }

    private static func record(_ id: String, _ path: [String], bundle: String = bundle, title: String? = nil, identifier: String? = nil,
                               submenu: Bool = false, enabled: Bool = true, mark: String? = nil, shortcut: String? = nil,
                               first: Int64 = 1_700_000_000_000, last: Int64 = 1_700_000_100_000) throws -> MenuCommandRecord {
        try MenuCommandRecord(menuCommandID: id, bundleID: bundle, path: path, topLevelTitle: title ?? path[0], identifier: identifier,
                              hasSubmenu: submenu, enabled: enabled, markChar: mark, cmdChar: shortcut, firstSeenMS: first, lastSeenMS: last)
    }

    private static func attempt(_ memory: Memory, from expected: MenuCommandRecord, to updated: MenuCommandRecord) async
        -> Result<MemoryReceipt, MenuCommandError> {
        do {
            return .success(try await memory.menus.update(from: expected, to: updated))
        } catch let error as MenuCommandError {
            return .failure(error)
        } catch {
            Issue.record("an error outside the menu contract: \(error)")
            return .failure(.missingCommand(menuCommandID: "unexpected"))
        }
    }

    private static let fixtures: [MenuCommandRecord] = [
        try! record("m-save", ["File", "Save As…"], identifier: "saveDocumentAs:", shortcut: "S"),
        try! record("m-deep", ["Format", "Font", "Kern", "Use Default"], mark: "✓"),
        try! record("m-parent", ["Format", "Font"], submenu: true),
        try! record("m-slash", ["Track", "Input/Output", "Bus 1/2"], identifier: ""),
        try! record("m-unicode", ["Modifica", "Café", "Cafe\u{301}"], title: "Modifica"),
        try! record("m-nul", ["View", "a\u{0}b", "x|y\u{1E}z", ""], enabled: false, mark: "", shortcut: ""),
        try! record("m-extreme", ["Window", "Zoom"], first: BrainClock.range.lowerBound, last: BrainClock.range.upperBound),
        try! record("m-same", ["Edit", "Copy"], first: 0, last: 0),
    ]

    @Test("every field and the ordered path are read back exactly after reopening: multilevel paths, slashes, Unicode composed and decomposed, NUL and separators, empty texts apart from absent ones, a disabled command, a submenu, mark and shortcut, the clock's extremes")
    func roundTrip() async throws {
        let memory = try await Self.open()
        for record in Self.fixtures { #expect(try await memory.menus.record(record) == .committed) }
        #expect(try await memory.count("SELECT count(*) FROM brain_menu_path_segments") == Int64(Self.fixtures.map(\.path.count).reduce(0, +)))
        await memory.store.close()
        let reopened = try await Self.open(at: memory.url)
        for record in Self.fixtures {
            let back = try #require(try await reopened.menus.menuCommand(record.menuCommandID))
            #expect(back.isExactly(record), Comment(rawValue: record.menuCommandID))
        }
        let all = try await reopened.menus.menuCommands(of: Self.bundle, pathKey: nil)
        #expect(all.map(\.menuCommandID) == ["m-same", "m-save", "m-parent", "m-deep", "m-unicode", "m-slash", "m-nul", "m-extreme"],
                "by path, segment by segment as bytes: a parent before its children, then by id")
        let paths = all.map { $0.path.map { Array($0.utf8) } }
        #expect(paths == paths.sorted { $0.lexicographicallyPrecedes($1) { $0.lexicographicallyPrecedes($1) } }, "ordered by path as bytes")
        #expect(try await reopened.menus.menuCommands(of: "nobody", pathKey: nil).isEmpty)
        #expect(try await reopened.menus.menuCommand("nothing") == nil)
        await reopened.store.close()
    }

    @Test("the commands rebuilt for the previous model keep every field its consumers read: the same command wins a query, a submenu parent never does")
    func oldConsumers() async throws {
        let memory = try await Self.open()
        for record in Self.fixtures { _ = try await memory.menus.record(record) }
        let back = try await memory.menus.menuCommands(of: Self.bundle, pathKey: nil).map(\.command)
        let original = Self.fixtures.map(\.command)
        for (stored, offered) in zip(back.sorted { $0.key < $1.key }, original.sorted { $0.key < $1.key }) {
            #expect(stored == offered, Comment(rawValue: offered.key))
        }
        let rebuilt = AppKnowledge(bundleID: Self.bundle, menuCommands: back), reference = AppKnowledge(bundleID: Self.bundle, menuCommands: original)
        for query in ["Save As", "Use Default", "Font", "Zoom", "Copy"] {
            #expect(rebuilt.bestMenuCommand(for: query) == reference.bestMenuCommand(for: query), Comment(rawValue: query))
        }
        #expect(rebuilt.bestMenuCommand(for: "Font")?.hasSubmenu != true)
        await memory.store.close()
    }

    @Test("two paths that join to one key and share an accessibility identifier are two commands, both found by the key as a hint")
    func collidingKeys() async throws {
        let memory = try await Self.open()
        let one = try Self.record("m1", ["A/B", "C"], identifier: "_NS:9"), two = try Self.record("m2", ["A", "B/C"], identifier: "_NS:9")
        #expect(one.pathKey == two.pathKey)
        #expect(try await memory.menus.record(one) == .committed)
        #expect(try await memory.menus.record(two) == .committed)
        let hinted = try await memory.menus.menuCommands(of: Self.bundle, pathKey: "A/B/C")
        #expect(hinted.map(\.menuCommandID) == ["m2", "m1"], "both found, ordered by path: \"A\" precedes \"A/B\"")
        #expect(try await memory.menus.menuCommand("m1")?.path == ["A/B", "C"])
        #expect(try await memory.menus.menuCommand("m2")?.path == ["A", "B/C"])
        await memory.store.close()
    }

    @Test("the same id and content is already applied; other content under the id, another application included, is a conflict with nothing written")
    func recordIdempotency() async throws {
        let memory = try await Self.open()
        let base = try Self.record("m1", ["Edit", "Café"], identifier: "copy:", shortcut: "C")
        #expect(try await memory.menus.record(base) == .committed)
        #expect(try await memory.menus.record(base) == .alreadyApplied)
        let before = try await memory.ledger()
        let others = [try Self.record("m1", ["Edit", "Cafe\u{301}"], identifier: "copy:", shortcut: "C"),
                      try Self.record("m1", ["Edit", "Café"], identifier: nil, shortcut: "C"),
                      try Self.record("m1", ["Edit", "Café"], identifier: "copy:", shortcut: ""),
                      try Self.record("m1", ["Edit", "Café"], identifier: "copy:", shortcut: "C", last: 1_700_000_100_001),
                      try Self.record("m1", ["Edit", "Café"], bundle: "test.other", identifier: "copy:", shortcut: "C")]
        for other in others {
            let error = await storeError { _ = try await memory.menus.record(other) }
            guard case .identity(let report)? = error else {
                Issue.record("expected a conflict, got \(String(describing: error))")
                continue
            }
            #expect(report.identity == "m1")
        }
        #expect(try await memory.ledger() == before, "no row, no segment and no other application written")
        #expect(try await memory.menus.menuCommand("m1")?.isExactly(base) == true)
        await memory.store.close()
    }

    @Test("an explicit update changes the observed fields against the record last read; its retry is already applied; a stale expectation, an identity field, a last sighting moved back or a missing command are refused with nothing written")
    func updates() async throws {
        let memory = try await Self.open()
        let v0 = try Self.record("m1", ["View", "Sidebar"], identifier: "toggleSidebar:", mark: nil, shortcut: "S")
        _ = try await memory.menus.record(v0)
        let v1 = try Self.record("m1", ["View", "Sidebar"], title: "Vista", identifier: nil, submenu: false, enabled: false, mark: "✓", shortcut: nil,
                                 last: 1_700_000_200_000)
        #expect(try await memory.menus.update(from: v0, to: v1) == .committed)
        #expect(try await memory.menus.update(from: v0, to: v1) == .alreadyApplied, "the retry of the update")
        #expect(try await memory.menus.menuCommand("m1")?.isExactly(v1) == true)
        let v2 = try Self.record("m1", ["View", "Sidebar"], title: "Vista", enabled: true, last: 1_700_000_300_000)
        #expect(await menuError { _ = try await memory.menus.update(from: v0, to: v2) } == .staleExpectation(menuCommandID: "m1"))
        #expect(try await memory.menus.menuCommand("m1")?.isExactly(v1) == true, "the stale update wrote nothing")
        let identities: [(String, MenuCommandRecord)] = [
            ("path", try Self.record("m1", ["View", "Side bar"], last: 1_700_000_300_000)),
            ("app", try Self.record("m1", ["View", "Sidebar"], bundle: "test.other", last: 1_700_000_300_000)),
            ("first_seen_ms", try Self.record("m1", ["View", "Sidebar"], first: 1_699_000_000_000, last: 1_700_000_300_000)),
            ("menu_command_id", try Self.record("m9", ["View", "Sidebar"], last: 1_700_000_300_000)),
        ]
        for (field, other) in identities {
            #expect(await menuError { _ = try await memory.menus.update(from: v1, to: other) } == .immutableField(menuCommandID: "m1", field: field))
        }
        let back = try Self.record("m1", ["View", "Sidebar"], title: "Vista", enabled: false, mark: "✓", last: 1_700_000_100_000)
        #expect(await menuError { _ = try await memory.menus.update(from: v1, to: back) } == .lastSeenBackwards(menuCommandID: "m1"))
        let ghost = try Self.record("ghost", ["X"])
        #expect(await menuError { _ = try await memory.menus.update(from: ghost, to: ghost) } == .missingCommand(menuCommandID: "ghost"))
        #expect(try await memory.menus.update(from: v1, to: v2) == .committed, "from the record last read, the next update goes through")
        #expect(try await memory.menus.menuCommand("m1")?.isExactly(v2) == true)
        await memory.store.close()
    }

    @Test("two callers updating one command from the same read: one commits, the other is stale and, after reading again, commits on top; no update is lost")
    func twoCallers() async throws {
        let first = try await Self.open()
        let second = try await Self.open(at: first.url)
        let v0 = try Self.record("m1", ["File", "Export"], shortcut: "E")
        _ = try await first.menus.record(v0)
        let a = try Self.record("m1", ["File", "Export"], enabled: false, shortcut: "E", last: 1_700_000_200_000)
        let b = try Self.record("m1", ["File", "Export"], mark: "•", shortcut: "E", last: 1_700_000_200_000)
        async let left  = Self.attempt(first, from: v0, to: a)
        async let right = Self.attempt(second, from: v0, to: b)
        let outcomes = await [left, right]
        let committed = outcomes.filter { $0 == .success(.committed) }.count
        let stale = outcomes.filter { $0 == .failure(.staleExpectation(menuCommandID: "m1")) }.count
        #expect(committed == 1 && stale == 1)
        let winner = try #require(try await first.menus.menuCommand("m1"))
        #expect(winner.isExactly(a) || winner.isExactly(b))
        let loserWanted = winner.isExactly(a) ? b : a
        let merged = try Self.record("m1", ["File", "Export"], enabled: winner.enabled && loserWanted.enabled,
                                     mark: winner.markChar ?? loserWanted.markChar, shortcut: "E", last: 1_700_000_300_000)
        #expect(try await second.menus.update(from: winner, to: merged) == .committed)
        #expect(try await first.menus.menuCommand("m1")?.isExactly(merged) == true)
        await second.store.close()
        await first.store.close()
    }

    @Test("a command whose segment the file refuses is rolled back whole, and the store goes on")
    func rollback() async throws {
        let memory = try await Self.open()
        _ = try await memory.store.write { transaction in
            try transaction.execute("CREATE TEMP TRIGGER refuse_boom BEFORE INSERT ON brain_menu_path_segments WHEN NEW.title = 'boom' BEGIN SELECT RAISE(ABORT, 'boom'); END")
        }
        let error = await storeError { _ = try await memory.menus.record(try Self.record("m1", ["File", "Open", "boom"])) }
        guard case .contract? = error else {
            Issue.record("expected the file's refusal, got \(String(describing: error))")
            return
        }
        #expect(try await memory.ledger() == [0, 0, 0], "no command, no segment, no application row")
        #expect(try await memory.menus.record(try Self.record("m1", ["File", "Open"])) == .committed)
        await memory.store.close()
    }

    @Test("rows the contract does not admit are refused by the reader with a typed error: no segment, a gap, a path_key that is not the path, a sighting out of the clock's range, invalid UTF-8; the store goes on")
    func malformedRows() async throws {
        let memory = try await Self.open()
        _ = try await memory.menus.record(try Self.record("seed", ["A"]))
        func plant(_ id: String, key: String, first: Int64 = 0, last: Int64 = 0, segments: [(Int64, String)]) async throws {
            try await memory.store.write { transaction in
                try transaction.execute(
                    "INSERT INTO brain_menu_commands (menu_command_id, app_id, path_key, top_level_title, has_submenu, last_observed_enabled, first_seen_ms, last_seen_ms) VALUES (?, 1, ?, 'T', 0, 1, ?, ?)",
                    [.text(id), .text(key), .integer(first), .integer(last)])
                for (position, title) in segments {
                    try transaction.execute(title == "\u{FFFD}bad"
                        ? "INSERT INTO brain_menu_path_segments (menu_command_id, position, title) VALUES (?, ?, CAST(X'61FF62' AS TEXT))"
                        : "INSERT INTO brain_menu_path_segments (menu_command_id, position, title) VALUES (?, ?, ?)",
                        title == "\u{FFFD}bad" ? [.text(id), .integer(position)] : [.text(id), .integer(position), .text(title)])
                }
            }
        }
        try await plant("none", key: "", segments: [])
        try await plant("gap", key: "A/C", segments: [(0, "A"), (2, "C")])
        try await plant("key", key: "A/B", segments: [(0, "A"), (1, "C")])
        try await plant("time", key: "A", last: 1 << 60, segments: [(0, "A")])
        try await plant("bytes", key: "x", segments: [(0, "\u{FFFD}bad")])
        let expected: [(String, MenuCommandError.Malformation)] = [
            ("none", .noSegments), ("gap", .segmentsNotContiguous), ("key", .pathKeyMismatch), ("time", .millisecondsOutOfRange(1 << 60)),
        ]
        for (id, malformation) in expected {
            #expect(await menuError { _ = try await memory.menus.menuCommand(id) } == .malformedRow(menuCommandID: id, malformation: malformation))
        }
        let text = await storeError { _ = try await memory.menus.menuCommand("bytes") }
        guard case .malformedText? = text else {
            Issue.record("expected the strict text reading's refusal, got \(String(describing: text))")
            return
        }
        let listing = await storeError { _ = try await memory.menus.menuCommands(of: Self.bundle, pathKey: nil) }
        guard case .malformedText? = listing else {
            Issue.record("the listing must refuse its first malformed command by id (\"bytes\"), not drop it: \(String(describing: listing))")
            return
        }
        #expect(await menuError { _ = try await memory.menus.menuCommands(of: Self.bundle, pathKey: "A/C") }
                == .malformedRow(menuCommandID: "gap", malformation: .segmentsNotContiguous), "never a truncated path")
        #expect(try await memory.menus.record(try Self.record("after", ["B"])) == .committed, "the store goes on")
        await memory.store.close()
    }

    @Test("references stay valid through an update: evidence that names the command still names it, with every foreign key intact")
    func referencesStay() async throws {
        let memory = try await Self.open()
        let v0 = try Self.record("m1", ["File", "Print…"], shortcut: "P")
        _ = try await memory.menus.record(v0)
        _ = try await SQLiteCaptureRepository(store: memory.store).record(MemoryEventRecord(
            eventID: "e1", source: .app, streamID: "w", kind: .observation, app: AppContextIdentity(bundleID: Self.bundle), occurredAtMS: 1))
        try await memory.store.write { transaction in
            try transaction.execute(
                "INSERT INTO brain_evidence (app_id, event_id, relation, assessed_by, assessment_version, assessed_at_ms, menu_command_id) VALUES (1, 'e1', 'supports', 'fixture', '1', 1, 'm1')")
        }
        let v1 = try Self.record("m1", ["File", "Print…"], enabled: false, shortcut: "P", last: 1_700_000_200_000)
        #expect(try await memory.menus.update(from: v0, to: v1) == .committed)
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE menu_command_id = 'm1'") == 1)
        #expect(try await memory.store.read { try $0.query("PRAGMA foreign_key_check", []) { _ in () }.count } == 0)
        await memory.store.close()
    }

    @Test("a later mutation of the brain's projection for the same application leaves the menus as they were: they live beside UIBrain, not in it")
    func besideTheBrain() async throws {
        let memory = try await Self.open()
        for record in Self.fixtures { _ = try await memory.menus.record(record) }
        let brain = SQLiteBrainRepository(store: memory.store)
        let detections = [BrainDetection(kind: .control, label: "Save", bounds: NormalizedRect(x: 0.5, y: 0.1, width: 0.03, height: 0.017))]
        _ = try await brain.ingest(detections, into: Self.bundle, now: Date(timeIntervalSince1970: 1_700_000_500), window: nil)
        _ = try await brain.ingest(detections, into: Self.bundle, now: Date(timeIntervalSince1970: 1_700_010_000), window: nil)
        #expect(try await brain.brain(of: Self.bundle)?.objects.count == 1)
        for record in Self.fixtures { #expect(try await memory.menus.menuCommand(record.menuCommandID)?.isExactly(record) == true) }
        #expect(try await memory.count("SELECT count(*) FROM brain_menu_commands") == Int64(Self.fixtures.count))
        await memory.store.close()
    }
}

/// The menu error an operation throws, or nil when it succeeds.
func menuError(_ operation: () async throws -> Void) async -> MenuCommandError? {
    do {
        try await operation()
        return nil
    } catch let error as MenuCommandError {
        return error
    } catch {
        Issue.record("expected a MenuCommandError, got \(error)")
        return nil
    }
}

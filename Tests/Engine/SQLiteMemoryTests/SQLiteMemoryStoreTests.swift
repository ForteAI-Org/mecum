//
//  SQLiteMemoryStoreTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Synchronization
import Testing

@Suite("The SQLite living memory foundation")
struct SQLiteMemoryStoreTests {

    @Test("the linked library is read from the binary and meets what the schema needs")
    func linkedLibrary() {
        print("SQLITE_LINKED version=\(SQLiteLibrary.version) number=\(SQLiteLibrary.versionNumber) sourceid=\(SQLiteLibrary.sourceID)")
        #expect(SQLiteLibrary.unmetRequirement() == nil)
        #expect(SQLiteLibrary.versionNumber >= 3_037_000)
        #expect(!SQLiteLibrary.sourceID.isEmpty)
        #expect(SQLiteLibrary.unmetRequirement(of: 3_036_000) == .strictTables)
        #expect(SQLiteLibrary.unmetRequirement(of: 3_040_000) == .concurrentWAL)
        #expect(SQLiteLibrary.unmetRequirement(of: 3_051_002) == .concurrentWAL)
        #expect(SQLiteLibrary.unmetRequirement(of: 3_051_003) == nil)
        #expect(SQLiteLibrary.unmetRequirement(of: 3_044_006) == nil)
        #expect(SQLiteLibrary.unmetRequirement(of: 3_045_000) == .concurrentWAL)
        #expect(SQLiteLibrary.unmetRequirement(of: 3_050_007) == nil)
    }

    @Test("an empty file is bootstrapped to schema 1 in WAL with full sync and foreign keys, and reopens as found")
    func bootstrap() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        let first = try await store.diagnostics()
        #expect(first.schemaVersion == 1)
        #expect(first.journalMode == "wal")
        #expect(first.synchronous == 2)
        #expect(first.foreignKeysEnabled)
        #expect(first.bootstrappedNow)
        #expect(first.libraryVersion == SQLiteLibrary.version)
        #expect(first.commits == 0)
        let shape = try await store.read { snapshot in try SchemaShape(snapshot) }
        #expect(shape == SchemaShape(tables: 48, triggers: 48, indexes: 31))
        let foreignKeyCheck = try await store.read { snapshot in
            try snapshot.query("PRAGMA foreign_key_check") { try $0.text(0) ?? "" }
        }
        #expect(foreignKeyCheck.isEmpty)
        let integrity = try await store.read { snapshot in
            try snapshot.query("PRAGMA integrity_check") { try $0.text(0) ?? "" }
        }
        #expect(integrity == ["ok"])
        await store.close()

        let again  = try await SQLiteMemoryStore.open(at: url)
        let second = try await again.diagnostics()
        #expect(second.schemaVersion == 1)
        #expect(second.journalMode == "wal")
        #expect(!second.bootstrappedNow)
        #expect(try await again.read { snapshot in try SchemaShape(snapshot) } == shape)
        await again.close()
    }

    @Test("every table of the resource is named by its parser")
    func tableNames() throws {
        let names = SQLiteMemorySchema.tableNames(in: try SQLiteMemorySchema.text())
        #expect(names.count == 48)
        #expect(names.first == "brain_apps")
        #expect(names.last == "memory_experience_uses")
        #expect(Set(names).count == 48)
    }

    @Test("an empty archive answers zero rows; a file that is not a database is an open error and stays as it was")
    func emptyArchiveVersusUnreadableFile() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 0)
        await store.close()

        let garbage = try temporaryDatabase("garbage")
        let bytes   = Data("this is not a database, and it must stay exactly this".utf8)
        try bytes.write(to: garbage)
        let error = await storeError { _ = try await SQLiteMemoryStore.open(at: garbage) }
        guard case .open(let fault)? = error else {
            Issue.record("expected .open, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 26)
        #expect(fault.phase == .bootstrap)
        #expect(try Data(contentsOf: garbage) == bytes)
        #expect(!FileManager.default.fileExists(atPath: garbage.path + "-wal"))
    }

    @Test("a directory that does not exist or cannot be written is an open error, and no file appears")
    func unwritablePath() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-missing-\(UUID().uuidString)/memory.sqlite")
        let error = await storeError { _ = try await SQLiteMemoryStore.open(at: missing) }
        guard case .open(let fault)? = error else {
            Issue.record("expected .open, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 14)
        #expect(fault.phase == .open)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let sealed = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-sealed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sealed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sealed.path) }
        let refused = await storeError {
            _ = try await SQLiteMemoryStore.open(at: sealed.appendingPathComponent("memory.sqlite"))
        }
        guard case .open(let sealedFault)? = refused else {
            Issue.record("expected .open, got \(String(describing: refused))")
            return
        }
        #expect(sealedFault.code.primary == 14 || sealedFault.code.primary == 8)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sealed.path).isEmpty)
    }

    @Test("a future schema version is refused and the file is neither downgraded nor reset")
    func futureSchema() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        await store.close()
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("PRAGMA user_version = 7")
        raw.close()

        let error = await storeError { _ = try await SQLiteMemoryStore.open(at: url) }
        #expect(error == .schema(.future(found: 7, supported: 1)))
        let check = try SQLiteConnection(path: url.path)
        #expect(try check.query("PRAGMA user_version") { $0.integer(0) }.first == 7)
        #expect(try check.query(
            "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ) { $0.integer(0) }.first == 48)
    }

    @Test("a version 1 file of an earlier development form whose columns match but whose constraints differ is refused untouched")
    func differentShapeRefused() async throws {
        let url = try temporaryDatabase()
        let ddl = try SQLiteMemorySchema.text()
        let earlier = ddl.replacingOccurrences(of: ",\n         'textSelectionChanged')),", with: ")),")
        #expect(earlier != ddl)
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute(earlier)
        try raw.execute("PRAGMA user_version = 1")
        raw.close()
        let before = try Data(contentsOf: url)

        let error = await storeError { _ = try await SQLiteMemoryStore.open(at: url) }
        #expect(error == .schema(.differentShape(["table memory_agent_actions"])))
        #expect(try Data(contentsOf: url) == before)

        let fresh = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        await fresh.close()
    }

    @Test("a version 0 file with somebody else's tables is refused and left exactly as found")
    func foreignTables() async throws {
        let url = try temporaryDatabase()
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("CREATE TABLE somebody_elses (x INTEGER)")
        raw.close()
        let before = try Data(contentsOf: url)

        let error = await storeError { _ = try await SQLiteMemoryStore.open(at: url) }
        #expect(error == .schema(.unknownTables(["somebody_elses"])))
        #expect(try Data(contentsOf: url) == before)
        let check = try SQLiteConnection(path: url.path)
        #expect(try check.query("PRAGMA user_version") { $0.integer(0) }.first == 0)
        #expect(try check.query("PRAGMA journal_mode") { try $0.text(0) }.first == "delete")
    }

    @Test("a version 1 file with a table missing is refused by name")
    func missingTables() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        await store.close()
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("DROP TABLE memory_experience_uses")
        raw.close()

        let error = await storeError { _ = try await SQLiteMemoryStore.open(at: url) }
        #expect(error == .schema(.missingTables(["memory_experience_uses"])))
    }

    @Test("two openers of one fresh file create the schema once and both find it")
    func twoOpeners() async throws {
        let url = try temporaryDatabase()
        async let first  = SQLiteMemoryStore.open(at: url)
        async let second = SQLiteMemoryStore.open(at: url)
        let (a, b) = try await (first, second)
        let da = try await a.diagnostics()
        let db = try await b.diagnostics()
        #expect([da.bootstrappedNow, db.bootstrappedNow].filter { $0 }.count == 1)
        #expect(da.schemaVersion == 1 && db.schemaVersion == 1)
        #expect(try await a.read { snapshot in try SchemaShape(snapshot) } == SchemaShape(tables: 48, triggers: 48, indexes: 31))
        await a.close()
        await b.close()
    }

    @Test("the five storage classes bind by value and read back")
    func bindings() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        try await store.write { transaction in
            try transaction.execute("CREATE TEMP TABLE probe (n, i, r, t, b)")
            try transaction.execute(
                "INSERT INTO probe VALUES (?, ?, ?, ?, ?)",
                [.null, .integer(-42), .real(2.5), .text("caf\u{E9} ' \" ; -- DROP"), .blob([0, 1, 2])]
            )
        }
        let row = try await store.write { transaction in
            try transaction.query("SELECT n, i, r, t, length(b), typeof(n) FROM probe") { row in
                (row.isNull(0), row.integer(1), row.real(2), try row.text(3), row.integer(4), try row.text(5))
            }.first
        }
        #expect(row?.0 == true)
        #expect(row?.1 == -42)
        #expect(row?.2 == 2.5)
        #expect(row?.3 == "caf\u{E9} ' \" ; -- DROP")
        #expect(row?.4 == 3)
        #expect(row?.5 == "null")
    }

    @Test("a statement that fails inside a transaction leaves no partial row, is a contract error, and the store goes on")
    func partialRollback() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let error = await storeError {
            try await store.write { transaction in
                try transaction.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (1, 'test.app')")
                try transaction.execute(
                    "INSERT INTO brain_app_window_epochs (app_id, window_family, epoch) VALUES (1, 'Main', -1)"
                )
            }
        }
        guard case .contract(let fault)? = error else {
            Issue.record("expected .contract, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 19)
        #expect(fault.code.extended == 275)
        #expect(fault.phase == .statement)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 0)
        #expect(try await store.diagnostics().commits == 0)

        let foreignKey = await storeError {
            _ = try await store.write { transaction in
                try transaction.execute("INSERT INTO brain_scene_roles (scene_id, role) VALUES ('nowhere', 'AXButton')")
            }
        }
        guard case .contract(let foreignKeyFault)? = foreignKey else {
            Issue.record("expected .contract, got \(String(describing: foreignKey))")
            return
        }
        #expect(foreignKeyFault.code.extended == 787)

        _ = try await store.write { transaction in
            try transaction.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (1, 'test.app')")
        }
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 1)
        #expect(try await store.diagnostics().commits == 1)
    }

    @Test("a committed write is seen by the next read on another store and on a bare connection")
    func visibility() async throws {
        let url    = try temporaryDatabase()
        let writer = try await SQLiteMemoryStore.open(at: url)
        _ = try await writer.write { transaction in
            try transaction.execute(
                "INSERT INTO brain_apps (app_id, bundle_id) VALUES (?, ?)",
                [.integer(1), .text("test.app")]
            )
        }
        let other = try await SQLiteMemoryStore.open(at: url)
        #expect(try await other.read { snapshot in try snapshot.query("SELECT bundle_id FROM brain_apps") { try $0.text(0) } } == ["test.app"])
        let raw = try SQLiteConnection(path: url.path)
        #expect(try raw.query("SELECT bundle_id FROM brain_apps") { try $0.text(0) } == ["test.app"])
        await writer.close()
        await other.close()
    }

    @Test("a write offered again with its identity is applied once, a different payload under it is a conflict, and equal facts under two identities are both kept")
    func idempotency() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let first = EventRow(id: "e1", key: "k1")
        #expect(try await record(first, in: store) == .committed)
        #expect(try await record(first, in: store) == .alreadyApplied)

        let changed  = EventRow(id: "e1", key: "k1", occurredAt: 200)
        let conflict = await storeError { _ = try await record(changed, in: store) }
        #expect(conflict == .identity(MemoryIdentityConflict(
            identity          : "e1",
            storedFingerprint : first.fingerprint,
            offeredFingerprint: changed.fingerprint
        )))

        #expect(try await record(EventRow(id: "e2", key: "k2"), in: store) == .committed)
        let rows = try await store.read { snapshot in
            try snapshot.query("SELECT event_id, occurred_at_ms FROM memory_events ORDER BY local_order") { row in
                (try row.text(0) ?? "", row.integer(1) ?? 0)
            }
        }
        #expect(rows.map(\.0) == ["e1", "e2"])
        #expect(rows.map(\.1) == [100, 100])
        #expect(try await store.diagnostics().commits == 3)
    }

    // The cycle's assertions are those the contract makes whatever the system's wake-ups: the
    // number of attempts and how long each pause really lasted belong to the scheduler (a 5 ms
    // pause has lasted 469 ms in a full run), so neither a minimum of attempts in a short budget
    // nor a ceiling on the time waited is asserted here; the exact schedule is the waiting rule's
    // own test, on `WaitingCycle`, in `SQLiteConfigurationTests`.
    @Test("one cycle of waiting for a lock held elsewhere pauses between attempts and ends in contention once another pause would overrun its budget, with nothing written, and the same write then commits once")
    func contention() async throws {
        let url           = try temporaryDatabase()
        let configuration = SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(150), retryPause: .milliseconds(5), maximumRetryPause: .milliseconds(20)
        )
        let store = try await SQLiteMemoryStore.open(at: url, configuration: configuration)
        let (events, observed) = AsyncStream<SQLiteMemoryStore.WaitEvent>.makeStream()
        await store.observeWaits { observed.yield($0) }
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")

        let bodies = BodyRuns()
        let error  = await storeError { _ = try await bodies.recordOnce(EventRow(id: "e1", key: "k1"), in: store) }
        guard case .contention(let fault, let attempts, let waited)? = error else {
            Issue.record("expected .contention, got \(String(describing: error))")
            return
        }
        // The lock is real and held elsewhere: every attempt met it at the begin, so no body ran.
        #expect(fault.code.primary == 5)
        #expect(fault.phase == .begin)
        #expect(bodies.count == 0)
        // At least the one pause the accepted configuration guarantees, each pause after a busy
        // attempt and announced once, and the cycle ended only because the next pause, at most
        // the maximum, would overrun the budget.
        #expect(attempts >= 2)
        #expect(waited > configuration.lockBudget - configuration.maximumRetryPause)
        await store.observeWaits(nil)
        observed.finish()
        var pauses: [SQLiteMemoryStore.WaitEvent] = []
        for await event in events { pauses.append(event) }
        #expect(pauses == (1..<attempts).map { .pausing(.begin, attempt: $0) })
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.busyRetries == attempts - 1)
        #expect(diagnostics.waited == waited)
        #expect(diagnostics.commits == 0)
        #expect(diagnostics.retainedWrites == 0)
        #expect(diagnostics.exhaustedCycles == 0)
        #expect(try rawCount("SELECT count(*) FROM memory_events", at: url) == 0)

        try holder.execute("ROLLBACK")
        #expect(try await bodies.recordOnce(EventRow(id: "e1", key: "k1"), in: store) == .committed)
        #expect(bodies.count == 1)
        #expect(try await store.diagnostics().commits == 1)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 1)
    }

    @Test("a write waiting for the lock waits outside any transaction: another write offered on the same connection during the wait meets the busy lock, not an open transaction, and both commit once after the release")
    func waitsOutsideTransaction() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url, configuration: SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(40), retryPause: .milliseconds(5), maximumRetryPause: .milliseconds(10)
        ))
        var events = await waits(of: store)
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")

        // `write` holds its work through every spent budget, so it is still waiting, suspended in a
        // pause, whenever the store runs anything else until the holder lets go.
        let held    = BodyRuns()
        let waiting = Task { await storeError { _ = try await held.record(EventRow(id: "e1", key: "k1"), in: store) } }
        while let event = await events.next() {
            if case .pausing(.begin, attempt: 1) = event { break }
        }
        let offered = BodyRuns()
        let error   = await storeError { _ = try await offered.recordOnce(EventRow(id: "e2", key: "k2"), in: store) }
        guard case .contention(let fault, _, _)? = error else {
            Issue.record("a begin on the shared connection met something other than the busy lock: \(String(describing: error))")
            waiting.cancel()
            return
        }
        #expect(fault.code.primary == 5 && fault.phase == .begin, "an open transaction would answer a nested begin, not busy")
        #expect(held.count == 0 && offered.count == 0)
        let during = try await store.diagnostics()
        #expect(during.retainedWrites == 1 && during.commits == 0)
        #expect(try rawCount("SELECT count(*) FROM memory_events", at: url) == 0)

        try holder.execute("ROLLBACK")
        holder.close()
        #expect(await waiting.value == nil)
        #expect(try await offered.recordOnce(EventRow(id: "e2", key: "k2"), in: store) == .committed)
        #expect(held.count == 1 && offered.count == 1)
        #expect(try await store.diagnostics().commits == 2)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 2)
        await store.close()
    }

    @Test("a write waiting for a lock ends with its task's cancellation and leaves nothing behind")
    func cancellation() async throws {
        let url    = try temporaryDatabase()
        let store  = try await SQLiteMemoryStore.open(at: url, configuration: SQLiteMemoryStore.Configuration(lockBudget: .seconds(10)))
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")

        let waiting = Task { await storeError { _ = try await record(EventRow(id: "e1", key: "k1"), in: store) } }
        try await Task.sleep(for: .milliseconds(60))
        waiting.cancel()
        let error = await waiting.value
        #expect(error == .cancelled(.begin))

        try holder.execute("ROLLBACK")
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 0)
        #expect(try await record(EventRow(id: "e1", key: "k1"), in: store) == .committed)
    }

    @Test("a lock inside the connection is classified as locked, apart from contention")
    func locked() throws {
        let connection = try SQLiteConnection(path: try temporaryDatabase().path)
        try connection.execute("CREATE TABLE t (x INTEGER)")
        try connection.execute("INSERT INTO t VALUES (1)")
        let cursor = try connection.prepare("SELECT x FROM t")
        #expect(try cursor.step())

        let failure = #expect(throws: SQLiteConnection.Failure.self) { try connection.execute("DROP TABLE t") }
        #expect(failure?.isLocked == true)
        #expect(failure?.isBusy == false)
        if let failure {
            guard case .locked(let fault) = MemoryStoreError(failure, phase: .statement) else {
                Issue.record("expected .locked")
                return
            }
            #expect(fault.code.primary == 6)
            #expect(fault.phase == .statement)
        }
        cursor.finalize()
        try connection.execute("DROP TABLE t")
    }

    @Test("a full database is a failure, apart from contention and from a contract error, and the transaction is whole")
    func full() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let pages = try await store.read { snapshot in try snapshot.query("PRAGMA page_count") { $0.integer(0) ?? 0 }.first ?? 0 }
        _ = try await store.write { transaction in
            // A pragma takes no bound value; the number is the file's own page count plus two.
            try transaction.execute("PRAGMA max_page_count = \(pages + 2)")
        }
        let padding = String(repeating: "x", count: 512)
        let error = await storeError {
            try await store.write { transaction in
                for index in 0..<10_000 {
                    try transaction.execute(
                        "INSERT INTO brain_apps (bundle_id) VALUES (?)",
                        [.text("app.\(index).\(padding)")]
                    )
                }
            }
        }
        guard case .failed(let fault)? = error else {
            Issue.record("expected .failed, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 13)
        #expect(fault.phase == .statement)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 0)
    }

    @Test("a read sees the committed state while another connection's write is open, and the new state after its commit")
    func snapshotRead() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        let other = try SQLiteConnection(path: url.path)
        try other.execute("BEGIN IMMEDIATE")
        try other.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (1, 'test.app')")

        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 0)
        #expect(try await store.diagnostics().busyRetries == 0)
        try other.execute("COMMIT")
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 1)
    }

    @Test("a store that was never opened, or was closed, says so instead of pretending to be empty")
    func unavailable() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase())
        #expect(await storeError { _ = try await store.diagnostics() } == .unavailable(.notOpened))
        #expect(await storeError { try await store.write { _ in } } == .unavailable(.notOpened))
        try await store.open()
        try await store.open()
        await store.close()
        #expect(await storeError { _ = try await store.diagnostics() } == .unavailable(.closed))
        #expect(await storeError { try await store.write { _ in } } == .unavailable(.closed))
        #expect(await storeError { try await store.read { _ in } } == .unavailable(.closed))
        #expect(await storeError { try await store.open() } == .unavailable(.closed))
    }
}

/// BodyRuns counts how often a write's body ran: the body runs only inside a begun transaction, so
/// a body that never ran is a write that never held one.
private final class BodyRuns: Sendable {

    private let runs = Mutex(0)

    var count: Int { runs.withLock { $0 } }

    /// `Support.record` and `Support.recordOnce`, counting each run of the body.
    func record(_ event: EventRow, in store: SQLiteMemoryStore) async throws -> MemoryReceipt {
        try await store.write { transaction in try self.insert(event, transaction) }
    }

    func recordOnce(_ event: EventRow, in store: SQLiteMemoryStore) async throws -> MemoryReceipt {
        try await store.attemptWrite { transaction in try self.insert(event, transaction) }
    }

    private func insert(_ event: EventRow, _ transaction: SQLiteTransaction) throws -> MemoryReceipt {
        runs.withLock { $0 += 1 }
        try transaction.execute(
            """
            INSERT INTO memory_events
                (event_id, source, source_stream_id, source_key, event_kind, occurred_at_ms, capture_status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(event.id), .text(event.source), .text(event.stream), .text(event.key),
             .text(event.kind), .integer(event.occurredAt), .text(event.capture)]
        )
        return .committed
    }
}

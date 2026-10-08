//
//  SQLiteRecoveryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// After a failure of the device or the file the store looks at the transaction it interrupted,
/// ends what the library left open, and says which it found. Nothing is retried on its own; the
/// caller learns the fact was not written and decides. Recovery on the same path is explicit: the
/// instance closes for good and a new one opens once the cause is removed.
@Suite("Failure, cleanup and recovery")
struct SQLiteRecoveryTests {

    private func capped(_ store: SQLiteMemoryStore) async throws {
        let pages = try await store.read { try $0.query("PRAGMA page_count") { $0.integer(0) ?? 0 }.first ?? 0 }
        _ = try await store.write { transaction in
            // A pragma takes no bound value; the number is the file's own page count plus two.
            try transaction.execute("PRAGMA max_page_count = \(pages + 2)")
        }
    }

    private func bigWrite(_ store: SQLiteMemoryStore, rows: Int = 400) async -> MemoryStoreError? {
        let padding = String(repeating: "x", count: 3000)
        return await storeError {
            _ = try await store.write { transaction in
                for index in 0..<rows {
                    try transaction.execute("INSERT INTO brain_apps (bundle_id) VALUES (?)", [.text("app.\(index).\(padding)")])
                }
            }
        }
    }

    @Test("a full database is a failure with its cleanup reported, nothing partial, no retry of its own, and the store goes on")
    func fullDatabase() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        try await capped(store)
        let error = await bigWrite(store)
        guard case .failed(let fault)? = error else {
            Issue.record("expected .failed, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 13)
        #expect(fault.phase == .statement)
        #expect(fault.cleanup == .alreadyRolledBack)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 0)
        let after = try await store.diagnostics()
        #expect(after.commits == 1)
        #expect(after.retainedWrites == 0)
        #expect(await store.liveHandles == 2)
        // The same fact offered again meets the same cause: refused again, not retried underneath.
        guard case .failed(let second)? = await bigWrite(store) else {
            Issue.record("expected .failed again")
            return
        }
        #expect(second.code.primary == 13)
        #expect(try await store.diagnostics().commits == 1)
        // Recovery is explicit: this instance closes for good; a new one on the same path, without the cause, writes.
        await store.close()
        #expect(await storeError { try await store.open() } == .unavailable(.closed))
        let recovered = try await SQLiteMemoryStore.open(at: url)
        #expect(!(try await recovered.diagnostics().bootstrappedNow))
        #expect(await bigWrite(recovered, rows: 40) == nil)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: recovered) == 40)
        #expect(try await recovered.read { try $0.query("PRAGMA integrity_check") { try $0.text(0) } } == ["ok"])
        await recovered.close()
    }

    @Test("a constraint failure leaves the transaction open, and the store's own rollback ends it")
    func contractFailureIsRolledBackExplicitly() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let error = await storeError {
            try await store.write { transaction in
                try transaction.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (1, 'test.app')")
                try transaction.execute("INSERT INTO brain_app_window_epochs (app_id, window_family, epoch) VALUES (1, 'Main', -1)")
            }
        }
        guard case .contract(let fault)? = error else {
            Issue.record("expected .contract, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 19)
        #expect(fault.cleanup == .rolledBack)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 0)
        await store.close()
    }

    @Test("the cleanup decision over what was observed: already rolled back, rolled back, or failed with the rollback's answer")
    func cleanupDecision() {
        typealias Code = MemoryStoreFault.Code
        #expect(SQLiteMemoryStore.cleanupOutcome(inTransaction: false, rollback: { nil }, stillInTransaction: { false }) == .alreadyRolledBack)
        #expect(SQLiteMemoryStore.cleanupOutcome(inTransaction: true, rollback: { nil }, stillInTransaction: { false }) == .rolledBack)
        let refused = SQLiteConnection.Failure(primary: 10, extended: 778, message: "disk I/O error")
        #expect(SQLiteMemoryStore.cleanupOutcome(inTransaction: true, rollback: { refused }, stillInTransaction: { true })
                == .failed(Code(primary: 10, extended: 778), "disk I/O error"))
        #expect(SQLiteMemoryStore.cleanupOutcome(inTransaction: true, rollback: { nil }, stillInTransaction: { true })
                == .failed(Code(primary: 0, extended: 0), "the connection stayed inside a transaction after ROLLBACK"))
    }

    @Test("a real I/O error in another process: the commit fails, nothing partial, the store goes on, and the file reopens whole once the cause is gone")
    func ioErrorInAnotherProcess() async throws {
        let url   = try temporaryDatabase()
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(url.path)").hasPrefix("opened bootstrapped=1"))
        #expect(try await probe.ask("write-apps 3 100") == "committed")
        #expect(try await probe.ask("limit-file-size wal").hasPrefix("limited "))
        let failed = try await probe.ask("write-apps 800 3000")
        #expect(failed == "error failed code=10/778 phase=commit cleanup=alreadyRolledBack", Comment(rawValue: failed))
        #expect(try await probe.ask("count-apps") == "apps 3")
        #expect(try await probe.ask("diagnostics").hasPrefix("diagnostics commits=1 "))
        #expect(try await probe.ask("unlimit-file-size") == "unlimited")
        #expect(try await probe.ask("write-apps 800 3000") == "committed")
        #expect(try await probe.ask("count-apps") == "apps 803")
        #expect(try await probe.ask("close") == "closed")
        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 803)
        #expect(try await store.read { try $0.query("PRAGMA integrity_check") { try $0.text(0) } } == ["ok"])
        await store.close()
    }
}

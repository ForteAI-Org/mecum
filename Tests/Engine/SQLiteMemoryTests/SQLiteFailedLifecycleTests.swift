//
//  SQLiteFailedLifecycleTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The `failed` lifecycle end to end: a failure inside a transaction whose cleanup then fails. The
/// cleanup's failure comes from the store's internal seam (`refuseNextRollback`), which answers the
/// rollback in place of running it and leaves the connection inside its transaction; the primary
/// failure is a real one of the library. Nothing is broken on the device: this proves the store's
/// path after such a cleanup, not a real fault and not a blackout.
@Suite("A cleanup that fails, end to end", .serialized)
struct SQLiteFailedLifecycleTests {

    private static let refused = SQLiteConnection.Failure(
        primary : 10,
        extended: 10,
        message : "rollback refused by the test's seam"
    )

    private static let quick = SQLiteMemoryStore.Configuration(
        lockBudget: .seconds(30), retryPause: .milliseconds(5), maximumRetryPause: .milliseconds(20)
    )

    private func constraintFailure(in store: SQLiteMemoryStore) async -> MemoryStoreError? {
        await storeError {
            try await store.write { transaction in
                try transaction.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (1, 'test.app')")
                try transaction.execute("INSERT INTO brain_app_window_epochs (app_id, window_family, epoch) VALUES (1, 'Main', -1)")
            }
        }
    }

    @Test("the primary failure and its failed cleanup are answered; the store lets go of both connections and the lock, answers failed to every later call until closed, and a new instance recovers the file")
    func failedAfterAFailedCleanup() async throws {
        let url   = try temporaryDatabase("failed-cleanup")
        let store = try await SQLiteMemoryStore.open(at: url)
        _ = try await record(EventRow(id: "before", key: "k0"), in: store)
        await store.refuseNextRollback(with: Self.refused)

        let error = await constraintFailure(in: store)
        guard case .contract(let primary)? = error else { Issue.record("expected the constraint, got \(String(describing: error))"); return }
        #expect(primary.code.primary == 19)
        #expect(primary.phase == .statement)
        #expect(primary.cleanup == .failed(MemoryStoreFault.Code(primary: 10, extended: 10), "rollback refused by the test's seam"))
        #expect(await store.liveHandles == 0, "both connections let go of")

        // Every later call answers the same reason, the primary fault with its cleanup, until the close.
        let reason = MemoryStoreError.unavailable(.failed(primary))
        #expect(await storeError { _ = try await store.diagnostics() } == reason)
        #expect(await storeError { _ = try await record(EventRow(id: "after", key: "k1"), in: store) } == reason)
        #expect(await storeError { _ = try await store.read { _ in () } } == reason)
        #expect(await storeError { _ = try await store.checkpoint() } == reason)
        #expect(await storeError { _ = try await store.snapshot(to: url.deletingLastPathComponent().appendingPathComponent("copy.sqlite")) } == reason)
        #expect(await storeError { try await store.open() } == reason, "a failed instance does not reopen")
        #expect(await storeError { try await store.open(.existingArchive) } == reason)
        #expect(await store.liveHandles == 0)

        // The lock went with the connection: another connection takes it at once, and the interrupted
        // transaction left nothing; what was committed before is there.
        let other = try SQLiteConnection(path: url.path)
        try other.execute("BEGIN IMMEDIATE")
        #expect(try other.query("SELECT count(*) FROM brain_apps") { $0.integer(0) }.first == 0)
        #expect(try other.query("SELECT count(*) FROM memory_events") { $0.integer(0) }.first == 1)
        try other.execute("ROLLBACK")
        other.close()

        // The close is definitive and is said as such, not as the failure.
        await store.close()
        #expect(await store.liveHandles == 0)
        #expect(await storeError { try await store.open() } == .unavailable(.closed))
        #expect(await storeError { _ = try await store.read { _ in () } } == .unavailable(.closed))

        // Recovery is a new instance on the same path: the file is whole and takes new writes.
        let recovered = try await SQLiteMemoryStore.open(at: url)
        #expect(!(try await recovered.diagnostics().bootstrappedNow))
        #expect(try await count("SELECT count(*) FROM memory_events", in: recovered) == 1)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: recovered) == 0)
        #expect(try await recovered.read { try $0.query("PRAGMA integrity_check") { try $0.text(0) } } == ["ok"])
        #expect(try await recovered.read { try $0.query("PRAGMA foreign_key_check") { _ in () }.count } == 0)
        _ = try await record(EventRow(id: "after-recovery", key: "k2"), in: recovered)
        #expect(try await count("SELECT count(*) FROM memory_events", in: recovered) == 2)
        await recovered.close()
    }

    @Test("a write already waiting for the lock when a read's cleanup fails answers the failure, not a close, and writes nothing")
    func aWaitingWriteMeetsTheFailure() async throws {
        let url    = try temporaryDatabase("failed-waiting")
        let store  = try await SQLiteMemoryStore.open(at: url, configuration: Self.quick)
        var events = await waits(of: store)
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")

        let waiting = Task { await storeError { _ = try await record(EventRow(id: "waiting", key: "kw"), in: store) } }
        #expect(await events.next() == .pausing(.begin, attempt: 1))
        #expect(try await store.diagnostics().retainedWrites == 1)

        // A real failure of the library inside the reader's transaction, whose rollback the seam refuses.
        await store.refuseNextRollback(with: Self.refused)
        let error = await storeError {
            _ = try await store.read { try $0.query("SELECT no_such_column FROM memory_events") { _ in () } }
        }
        guard case .contract(let primary)? = error else { Issue.record("expected the read's failure, got \(String(describing: error))"); return }
        #expect(primary.code.primary == 1)
        #expect(primary.cleanup == .failed(MemoryStoreFault.Code(primary: 10, extended: 10), "rollback refused by the test's seam"))
        #expect(await store.liveHandles == 0)

        try holder.execute("ROLLBACK")
        holder.close()
        let answer = await waiting.value
        #expect(answer == .unavailable(.failed(primary)), "the waiting write is told why, after its pause")
        #expect(try rawCount("SELECT count(*) FROM memory_events WHERE event_id = 'waiting'", at: url) == 0)
        #expect(await store.liveHandles == 0)
        await store.close()
        #expect(await storeError { _ = try await record(EventRow(id: "waiting", key: "kw"), in: store) } == .unavailable(.closed))

        let recovered = try await SQLiteMemoryStore.open(at: url)
        #expect(try await record(EventRow(id: "waiting", key: "kw"), in: recovered) == .committed, "the same fact, offered again by its owner")
        await recovered.close()
    }

    @Test("a cleanup that succeeds is not this path: the seam unused, a constraint failure rolls back and the store goes on")
    func anOrdinaryCleanupStaysOpen() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase("ordinary-cleanup"))
        guard case .contract(let fault)? = await constraintFailure(in: store) else { Issue.record("expected the constraint"); return }
        #expect(fault.cleanup == .rolledBack)
        #expect(await store.liveHandles == 2)
        _ = try await record(EventRow(id: "goes-on", key: "k"), in: store)
        await store.close()
    }
}

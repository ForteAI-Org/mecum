//
//  SQLiteLifecycleTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The store's lifecycle under a busy lock, synchronized on the store's own wait events rather
/// than on time: a test resumes exactly when the store announces the pause it is about to take.
@Suite("The store's lifecycle and its retained writes")
struct SQLiteLifecycleTests {

    @Test("a close during an open still waiting for the lock prevails: the open answers closed, and no handle survives")
    func closeDuringOpen() async throws {
        let url    = try temporaryDatabase()
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")
        let store = SQLiteMemoryStore(url: url, configuration: SQLiteMemoryStore.Configuration(lockBudget: .seconds(30)))
        var events = await waits(of: store)

        let opening = Task { await storeError { try await store.open() } }
        let first   = await events.next()
        #expect(first == .pausing(.bootstrap, attempt: 1))
        #expect(await store.liveHandles == 1)

        await store.close()
        try holder.execute("ROLLBACK")
        holder.close()
        #expect(await opening.value == .unavailable(.closed))
        #expect(await store.liveHandles == 0)
        #expect(await storeError { _ = try await store.diagnostics() } == .unavailable(.closed))
        #expect(await storeError { try await store.open() } == .unavailable(.closed))
        #expect(await storeError { _ = try await store.write { _ in } } == .unavailable(.closed))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    @Test("two opens of one instance share the open in flight; both answer once the lock is free")
    func concurrentOpensOfOneInstance() async throws {
        let url    = try temporaryDatabase()
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")
        let store  = SQLiteMemoryStore(url: url, configuration: SQLiteMemoryStore.Configuration(lockBudget: .seconds(30)))
        var events = await waits(of: store)

        let first  = Task { await storeError { try await store.open() } }
        _ = await events.next()
        let second = Task { await storeError { try await store.open() } }
        #expect(await store.liveHandles == 1)

        try holder.execute("ROLLBACK")
        holder.close()
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.schemaVersion == 1)
        #expect(diagnostics.bootstrappedNow)
        #expect(await store.liveHandles == 2)
        await store.close()
        #expect(await store.liveHandles == 0)
    }

    @Test("an open that fails for the file's sake leaves the store not opened, so it may be tried again")
    func failedOpenCanBeRetried() async throws {
        let url = try temporaryDatabase()
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("PRAGMA user_version = 9")
        let store = SQLiteMemoryStore(url: url)
        #expect(await storeError { try await store.open() } == .schema(.future(found: 9, supported: 1)))
        #expect(await store.liveHandles == 0)
        try raw.execute("PRAGMA user_version = 0")
        raw.close()
        try await store.open()
        #expect(try await store.diagnostics().schemaVersion == 1)
        #expect(await store.liveHandles == 2)
        await store.close()
    }

    @Test("a write offered while the lock is held past a whole budget is held by the store, then committed once, with its producer's action never repeated")
    func retainedWriteOutlivesTheBudget() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url, configuration: SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(40), retryPause: .milliseconds(5), maximumRetryPause: .milliseconds(10)
        ))
        var events = await waits(of: store)
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")

        // The simulated producer: one UI action, then the fact of that action, offered once.
        let producer = Task { () -> (actions: Int, error: MemoryStoreError?) in
            var actions = 0
            actions += 1
            let error = await storeError { _ = try await record(EventRow(id: "act-1", key: "k1"), in: store) }
            return (actions, error)
        }

        var exhausted = 0
        while exhausted < 2, let event = await events.next() {
            if case .cycleExhausted(let phase, let attempts, _) = event {
                exhausted += 1
                #expect(phase == .begin)
                #expect(attempts >= 2)
            }
        }
        let waiting = try await store.diagnostics()
        #expect(waiting.retainedWrites == 1)
        #expect(waiting.exhaustedCycles >= 2)
        #expect(waiting.commits == 0)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 0)
        // The store and the main actor both answer while the write waits: nothing spins or blocks.
        let onMain = await MainActor.run { 1 }
        #expect(onMain == 1)

        try holder.execute("ROLLBACK")
        holder.close()
        let outcome = await producer.value
        #expect(outcome.error == nil)
        #expect(outcome.actions == 1)
        let done = try await store.diagnostics()
        #expect(done.retainedWrites == 0)
        #expect(done.commits == 1)
        #expect(try await count("SELECT count(*) FROM memory_events WHERE event_id = 'act-1'", in: store) == 1)
        await store.close()
    }

    @Test("a retained write ends with the store's close, with nothing written and nothing held")
    func retainedWriteEndsWithClose() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url, configuration: SQLiteMemoryStore.Configuration(lockBudget: .milliseconds(40)))
        var events = await waits(of: store)
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")

        let producer = Task { await storeError { _ = try await record(EventRow(id: "act-1", key: "k1"), in: store) } }
        _ = await events.next()
        #expect(try await store.diagnostics().retainedWrites == 1)

        await store.close()
        try holder.execute("ROLLBACK")
        #expect(await producer.value == .unavailable(.closed))
        #expect(await store.liveHandles == 0)
        let check = try SQLiteConnection(path: url.path)
        #expect(try check.query("SELECT count(*) FROM memory_events") { $0.integer(0) }.first == 0)
        check.close()
        holder.close()
    }

    @Test("a retained write ends with its task's cancellation, with nothing written")
    func retainedWriteEndsWithCancellation() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url, configuration: SQLiteMemoryStore.Configuration(lockBudget: .milliseconds(40)))
        var events = await waits(of: store)
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")

        let producer = Task { await storeError { _ = try await record(EventRow(id: "act-1", key: "k1"), in: store) } }
        var exhausted = 0
        while exhausted < 1, let event = await events.next() {
            if case .cycleExhausted = event { exhausted += 1 }
        }
        producer.cancel()
        let error = await producer.value
        #expect(error == .cancelled(.begin))
        try holder.execute("ROLLBACK")
        holder.close()
        #expect(try await store.diagnostics().retainedWrites == 0)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 0)
        await store.close()
    }
}

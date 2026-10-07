//
//  MemoryClosingTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import AutomationRuntime
import Foundation
import Memory
@testable import SQLiteMemory
import Synchronization
import Testing

/// Gate holds a task at a point a test chooses until the test opens it. Waiting at it is a sleep in
/// small steps, so a cancelled task leaves the gate at once with `CancellationError`, which the gate
/// counts.
final class Gate: Sendable {

    private let opened    = Mutex(false)
    private let arrived   = Mutex(0)
    private let cancelled = Mutex(0)

    func pass() async throws {
        arrived.withLock { $0 += 1 }
        do {
            while !opened.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            cancelled.withLock { $0 += 1 }
            throw error
        }
    }

    func open() { opened.withLock { $0 = true } }

    var arrivals: Int { arrived.withLock { $0 } }

    /// How many tasks left the gate because they were cancelled while waiting at it.
    var cancellations: Int { cancelled.withLock { $0 } }

    /// Waits until a task reached the gate, at most `limit`.
    func reached(within limit: Duration = .seconds(5)) async -> Bool {
        await C.eventually(within: limit) { self.arrivals > 0 }
    }
}

struct SkipBackup: Error {}

/// Signal is raised once by the task under test, at a point it reached, and read by the test.
final class Signal: Sendable {

    private let raised = Mutex(false)

    func raise() { raised.withLock { $0 = true } }

    var isRaised: Bool { raised.withLock { $0 } }
}

/// C (closing) is what the closing tests share: a service of their own, events of known identity,
/// and a way to time a call that may never return without the test hanging on it.
enum C {

    static let budget    = Duration.seconds(1)
    /// What a close may take beyond its bound: the polling of its waits and the hops between actors.
    static let tolerance = Duration.milliseconds(150)

    static func service(budget: Duration = budget, pagesPerStep: Int32 = 256,
                        backupInterval: Duration = .seconds(86_400)) throws -> MemoryService {
        MemoryService(directory: try W.directory(), configuration: MemoryService.Configuration(
            store: SQLiteMemoryStore.Configuration(snapshotPagesPerStep: pagesPerStep),
            closingBudget: budget, backupInterval: backupInterval
        ))
    }

    static func event(_ id: String) -> MemoryEventRecord {
        MemoryEventRecord(eventID: id, source: .system, streamID: "closing-tests", kind: .observation,
                          occurredAtMS: 1_790_000_000_000)
    }

    /// Enqueues the writes of `count` events named `prefix-0`, `prefix-1`, ….
    static func offer(_ service: MemoryService, _ prefix: String, count: Int) async {
        for index in 0..<count {
            let event = event("\(prefix)-\(index)")
            await service.enqueue("event") { _ = try await $0.captures.record(event) }
        }
    }

    /// The events of the prefix the archive holds, read by a service of its own after `service` closed.
    static func stored(in service: MemoryService, _ prefix: String, count: Int) async throws -> Int {
        let reader = MemoryService(directory: service.directory)
        defer { Task { await reader.close() } }
        var found = 0
        for index in 0..<count where try await reader.event("\(prefix)-\(index)") != nil { found += 1 }
        return found
    }

    /// How long `body` took, or nil when it had not returned after `limit`. The body keeps running. The
    /// measure is printed with the calling test's name, as evidence of the bound.
    static func elapsed(_ limit: Duration, caller: String = #function,
                        _ body: @escaping @Sendable () async -> Void) async -> Duration? {
        let finished = Mutex<Duration?>(nil)
        let start    = ContinuousClock.now
        Task { await body(); finished.withLock { $0 = start.duration(to: .now) } }
        var took: Duration?
        while start.duration(to: .now) < limit {
            if let done = finished.withLock({ $0 }) { took = done; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        took = took ?? finished.withLock { $0 }
        print("MEMORY-CLOSE \(caller): \(took.map { "\($0)" } ?? "not returned within \(limit)")")
        return took
    }

    /// Waits until the condition holds, at most `limit`; true when it held.
    static func eventually(within limit: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while !(await condition()) {
            guard start.duration(to: .now) < limit else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    static func files(_ service: MemoryService, _ marker: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: service.directory.path).filter { $0.contains(marker) }
    }

    /// Every write the status accounts for, however it ended.
    static func accounted(_ status: MemoryService.Status) -> Int {
        status.written + status.failed + status.partial + status.dropped + status.unsettled + status.pending + status.inFlight
    }
}

/// C05: closing the memory within one bound, saving everything in the ordinary case, accounting for
/// every write it could not save by what it committed, and never publishing an incomplete copy.
@Suite("Closing the memory: one bound, every write accounted for, no incomplete copy")
struct MemoryClosingTests {

    @Test("ordinary close: every offered write is saved and none is left unaccounted")
    func nominal() async throws {
        let service = try C.service()
        await service.setBeforeBackup { throw SkipBackup() }
        await C.offer(service, "nominal", count: 200)
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        #expect(took != nil)
        let status = await service.status()
        #expect(status.written == 200 && status.failed == 0 && status.partial == 0 && status.dropped == 0)
        #expect(status.unsettled == 0 && status.pending == 0 && status.inFlight == 0)
        #expect(try await C.stored(in: service, "nominal", count: 200) == 200)
    }

    @Test("a copy held at its start when the close begins: it is cancelled, the writes are saved, nothing is published")
    func copyHeldAtItsStart() async throws {
        let service = try C.service()
        let gate = Gate()
        await service.setBeforeBackup { try await gate.pass() }
        _ = try await service.ready()
        #expect(await gate.reached())
        await C.offer(service, "within", count: 20)
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        defer { gate.open() }
        #expect(took != nil, "the close waited for a copy past its bound")
        #expect(gate.cancellations == 1, "the close cancelled the copy")
        #expect(try C.files(service, ".backup-").isEmpty, "no copy was finished, so none may be published")
        #expect(try C.files(service, ".partial").isEmpty)
        #expect(try await C.stored(in: service, "within", count: 20) == 20, "the writes did not wait for the copy")
        #expect(await service.status().lastClose?.contains("stopped with nothing published") == true)
    }

    @Test("a copy held between two of its steps, its partial file on disk: the close cancels it there, removes the partial file and publishes nothing")
    func copyHeldBetweenTwoSteps() async throws {
        let service = try C.service(pagesPerStep: 1, backupInterval: .zero)
        let start = Gate(), step = Gate()
        await service.setBeforeBackup { try await start.pass() }
        _ = try await service.ready()
        #expect(await start.reached(), "the day's copy begins at the open")
        await service.holdCopySteps { try await step.pass() }
        start.open()
        #expect(await step.reached(), "the copy reached the gate between its first two steps")
        #expect(try !C.files(service, ".partial").isEmpty, "the copy is in progress: its partial file exists")

        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        #expect(took != nil, "the close returned within its bound")
        #expect(step.cancellations == 1, "the copy was cancelled while it waited between two steps")
        #expect(try C.files(service, ".partial").isEmpty, "the cancelled copy left no partial file")
        #expect(try C.files(service, ".backup-").isEmpty, "the cancelled copy published nothing")
        let summary = await service.status().lastClose ?? ""
        #expect(summary.contains("stopped with nothing published"), "\(summary)")
    }

    @Test("writes held by a lock past the bound: the close returns on time, the queued writes are dropped, the running one failed with nothing committed")
    func lockPastBound() async throws {
        let service = try C.service()
        await service.setBeforeBackup { throw SkipBackup() }
        _ = try await service.ready()
        let lock = try SQLiteConnection(path: service.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        await C.offer(service, "locked", count: 5)
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        #expect(took != nil, "the close hung on a lock")
        let status = await service.status()
        #expect(C.accounted(status) == 5, "offered 5, \(status)")
        #expect(status.written == 0 && status.failed == 1 && status.dropped == 4 && status.partial == 0 && status.unsettled == 0,
                "\(status)")
        try lock.execute("ROLLBACK")
        lock.close()
        #expect(try await C.stored(in: service, "locked", count: 5) == 0)
    }

    @Test("writes held by a lock released within the bound are all saved")
    func lockWithinBound() async throws {
        let service = try C.service()
        await service.setBeforeBackup { throw SkipBackup() }
        _ = try await service.ready()
        let lock = try SQLiteConnection(path: service.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        await C.offer(service, "released", count: 5)
        let started = ContinuousClock.now
        let closing = Task { await service.close() }
        try await Task.sleep(for: .milliseconds(200))
        try lock.execute("ROLLBACK")
        let took = await C.elapsed(C.budget + C.tolerance) { await closing.value }
        #expect(took != nil && started.duration(to: .now) < C.budget + C.tolerance)
        lock.close()
        #expect(try await C.stored(in: service, "released", count: 5) == 5)
        #expect(await service.status().written == 5)
    }

    @Test("a write suspended before its commit when the bound comes: cancelled, counted failed, nothing of it stored")
    func suspendedBeforeCommit() async throws {
        let service = try C.service()
        await service.setBeforeBackup { throw SkipBackup() }
        let gate = Gate(), event = C.event("before-commit")
        await service.enqueue("held write") { repositories in
            try await gate.pass()
            _ = try await repositories.captures.record(event)
        }
        #expect(await gate.reached())
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        defer { gate.open() }
        #expect(took != nil)
        let status = await service.status()
        #expect(status.failed == 1 && status.partial == 0 && status.written == 0 && status.unsettled == 0, "\(status)")
        #expect(try await C.stored(in: service, "before-commit", count: 1) == 0)
    }

    @Test("a write suspended after its commit when the bound comes: counted partial, not failed, and what it committed is stored")
    func suspendedAfterCommit() async throws {
        let service = try C.service()
        await service.setBeforeBackup { throw SkipBackup() }
        let gate = Gate(), event = C.event("after-commit-0")
        await service.enqueue("held write") { repositories in
            _ = try await repositories.captures.record(event)
            try await gate.pass()
        }
        #expect(await gate.reached())
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        defer { gate.open() }
        #expect(took != nil)
        let status = await service.status()
        #expect(status.partial == 1 && status.failed == 0 && status.written == 0 && status.unsettled == 0, "\(status)")
        #expect(status.lastFailure?.contains("after 1 of its changes were saved") == true, "\(status.lastFailure ?? "")")
        #expect(try await C.stored(in: service, "after-commit", count: 1) == 1)
    }

    @Test("a write suspended after its commit and let go within the bound is written")
    func suspendedAfterCommitReleased() async throws {
        let service = try C.service()
        await service.setBeforeBackup { throw SkipBackup() }
        let gate = Gate(), event = C.event("released-0")
        await service.enqueue("held write") { repositories in
            _ = try await repositories.captures.record(event)
            try await gate.pass()
        }
        #expect(await gate.reached())
        Task { try? await Task.sleep(for: .milliseconds(150)); gate.open() }
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        #expect(took != nil)
        let status = await service.status()
        #expect(status.written == 1 && status.failed == 0 && status.partial == 0 && status.unsettled == 0, "\(status)")
    }

    @Test("a write that holds the store synchronously past the bound: the whole close still returns on time, the write is unsettled, then counted by how it ended, and the presence lock is let go only once the store closed")
    func storeHeldSynchronously() async throws {
        let service = try C.service()
        await service.setBeforeBackup { throw SkipBackup() }
        let event = C.event("held-store-0")
        let entered = Signal()
        await service.enqueue("long transaction") { repositories in
            _ = try await repositories.captures.record(event)
            try await repositories.store.write { transaction in
                entered.raise()
                // Not cooperative: the store's actor is held, as by a long transaction of a producer.
                usleep(1_600_000)
                _ = try transaction.query("SELECT count(*) FROM memory_events") { $0.integer(0) }
            }
        }
        #expect(await C.eventually { entered.isRaised }, "the long transaction began")
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        #expect(took != nil, "the close waited on a store held synchronously")
        let closed = await service.status()
        #expect(closed.unsettled == 1 && closed.written == 0 && closed.failed == 0, "\(closed)")
        #expect(closed.lastClose?.contains("still closing at the bound") == true, "\(closed.lastClose ?? "")")
        #expect(closed.lastClose?.contains("after 1 commits") == true, "\(closed.lastClose ?? "")")
        #expect(try SQLiteMemoryPresence.take(.exclusive, of: service.url) == nil, "the store still holds the archive")

        #expect(await C.eventually(within: .seconds(4)) { await service.status().unsettled == 0 })
        let ended = await service.status()
        #expect(ended.written == 1 && ended.unsettled == 0 && ended.failed == 0 && ended.partial == 0, "\(ended)")
        #expect(await C.eventually(within: .seconds(2)) { (try? SQLiteMemoryPresence.take(.exclusive, of: service.url)) ?? nil != nil },
                "the presence lock is let go once the store closed")
    }

    @Test("two closes at once make one stop; a write, a read and an open asked during the close are refused; no copy starts")
    func reentrantClose() async throws {
        let service = try C.service()
        let gate = Gate()
        await service.setBeforeBackup { throw SkipBackup() }
        await service.enqueue("held write") { _ in try await gate.pass() }
        #expect(await gate.reached())
        let copies = Gate()
        await service.setBeforeBackup { try await copies.pass() }
        let first  = Task { await service.close() }
        let second = Task { await service.close() }
        try await Task.sleep(for: .milliseconds(50))
        await service.enqueue("late write") { _ in }
        await #expect(throws: MemoryUnavailable.self) { _ = try await service.ready() }
        await #expect(throws: MemoryUnavailable.self) { _ = try await service.brain(of: "com.example.app") }
        gate.open()
        let took = await C.elapsed(C.budget + C.tolerance) { await first.value; await second.value }
        #expect(took != nil)
        let status = await service.status()
        #expect(C.accounted(status) == 2, "two offered, \(status)")
        #expect(status.written == 1 && status.dropped == 1, "\(status)")
        #expect(status.state == .closed)
        #expect(copies.arrivals == 0, "no copy starts once the close began")
    }

    @Test("a process can tell, without waiting, whether a shared memory still has writes or a copy to finish")
    func unfinishedWorkIsVisible() async throws {
        let directory = try W.directory()
        let service = MemoryService.shared(for: directory)
        await service.setBeforeBackup { throw SkipBackup() }
        let gate = Gate()
        await service.enqueue("held write") { _ in try await gate.pass() }
        #expect(await gate.reached())
        #expect(MemoryService.hasUnfinishedWork, "a write in flight is unfinished work")
        gate.open()
        #expect(await service.flush(within: .seconds(5)))
        await service.close()
        #expect(!MemoryService.hasUnfinishedWork, "a closed memory has nothing left")
    }
}

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
/// small steps, so a cancelled task leaves the gate at once with `CancellationError`.
final class Gate: Sendable {

    private let opened  = Mutex(false)
    private let arrived = Mutex(0)

    func pass() async throws {
        arrived.withLock { $0 += 1 }
        while !opened.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
    }

    func open() { opened.withLock { $0 = true } }

    var arrivals: Int { arrived.withLock { $0 } }

    /// Waits until a task reached the gate, at most `limit`.
    func reached(within limit: Duration = .seconds(5)) async -> Bool {
        let start = ContinuousClock.now
        while arrivals == 0 {
            guard start.duration(to: .now) < limit else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}

struct SkipBackup: Error {}

/// C (closing) is what the closing tests share: a service of their own, events of known identity,
/// and a way to time a call that may never return without the test hanging on it.
enum C {

    static let budget    = Duration.seconds(1)
    static let tolerance = Duration.milliseconds(600)

    static func service(budget: Duration = budget, pagesPerStep: Int32 = 256) throws -> MemoryService {
        MemoryService(directory: try W.directory(), configuration: MemoryService.Configuration(
            store: SQLiteMemoryStore.Configuration(snapshotPagesPerStep: pagesPerStep),
            closingBudget: budget
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

    /// How long `body` took, or nil when it had not returned after `limit`. The body keeps running.
    static func elapsed(_ limit: Duration, _ body: @escaping @Sendable () async -> Void) async -> Duration? {
        let finished = Mutex<Duration?>(nil)
        let start    = ContinuousClock.now
        Task { await body(); finished.withLock { $0 = start.duration(to: .now) } }
        while start.duration(to: .now) < limit {
            if let done = finished.withLock({ $0 }) { return done }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return finished.withLock { $0 }
    }

    static func files(_ service: MemoryService, _ marker: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: service.directory.path).filter { $0.contains(marker) }
    }
}

/// C05: closing the memory within one bound, saving everything in the ordinary case, accounting for
/// every write it could not save, and never publishing an incomplete copy.
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
        #expect(status.written == 200 && status.failed == 0 && status.dropped == 0 && status.pending == 0)
        #expect(try await C.stored(in: service, "nominal", count: 200) == 200)
    }

    @Test("a copy held at its start and let go within the bound: the close waits, the writes are saved, the copy is whole")
    func backupWithinBound() async throws {
        let service = try C.service()
        let gate = Gate()
        await service.setBeforeBackup { try await gate.pass() }
        _ = try await service.ready()
        #expect(await gate.reached())
        await C.offer(service, "within", count: 20)
        Task { try? await Task.sleep(for: .milliseconds(200)); gate.open() }
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        #expect(took != nil)
        #expect(try await C.stored(in: service, "within", count: 20) == 20)
        #expect(try C.files(service, ".partial").isEmpty)
    }

    @Test("a copy held past the bound: the close returns on time, the copy is abandoned and none is published")
    func backupPastBound() async throws {
        let service = try C.service()
        let gate = Gate()
        await service.setBeforeBackup { try await gate.pass() }
        _ = try await service.ready()
        #expect(await gate.reached())
        await C.offer(service, "past", count: 20)
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        defer { gate.open() }
        #expect(took != nil, "the close waited for a copy past its bound")
        #expect(try C.files(service, ".backup-").isEmpty, "no copy was finished, so none may be published")
        #expect(try C.files(service, ".partial").isEmpty)
        #expect(try await C.stored(in: service, "past", count: 20) == 20, "the writes did not wait for the copy")
    }

    @Test("a copy cancelled between two of its steps leaves no partial file and publishes nothing incomplete")
    func backupCancelledMidCopy() async throws {
        let service = try C.service(budget: .milliseconds(300), pagesPerStep: 1)
        await service.setBeforeBackup { throw SkipBackup() }
        await C.offer(service, "bulk", count: 3000)
        #expect(await service.flush(within: .seconds(20)))
        await service.close()

        let copying = MemoryService(directory: service.directory, configuration: MemoryService.Configuration(
            store: SQLiteMemoryStore.Configuration(snapshotPagesPerStep: 1), closingBudget: .milliseconds(300),
            backupInterval: .zero
        ))
        let gate = Gate(), stepping = Gate()
        await copying.setBeforeBackup { try await gate.pass() }
        _ = try await copying.ready()
        #expect(await gate.reached())
        await copying.observeStoreWaits { event in
            if case .yielding(.snapshot, _) = event, stepping.arrivals == 0 { Task { try? await stepping.pass() } }
        }
        gate.open()
        #expect(await stepping.reached())
        let took = await C.elapsed(.milliseconds(300) + C.tolerance) { await copying.close() }
        stepping.open()
        #expect(took != nil)
        #expect(try C.files(copying, ".partial").isEmpty)
        for copy in try C.files(copying, ".backup-") {
            let raw = try SQLiteConnection(path: copying.directory.appendingPathComponent(copy).path, readOnly: true)
            #expect(try raw.query("PRAGMA integrity_check") { try $0.text(0) } == ["ok"], "a published copy is whole")
            raw.close()
        }
    }

    @Test("writes held by another process's lock past the bound: the close returns on time and every write is accounted for")
    func lockPastBound() async throws {
        let service = try C.service()
        await service.setBeforeBackup { throw SkipBackup() }
        _ = try await service.ready()
        let lock = try SQLiteConnection(path: service.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        await C.offer(service, "locked", count: 5)
        let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
        #expect(took != nil, "the close hung on a lock")
        try? await Task.sleep(for: .milliseconds(300))
        let status = await service.status()
        #expect(status.written + status.failed + status.dropped == 5, "offered 5, accounted \(status)")
        #expect(status.pending == 0)
        try lock.execute("ROLLBACK")
        lock.close()
        #expect(try await C.stored(in: service, "locked", count: 5) == status.written)
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

    @Test("a write already taken from the queue when the close begins is counted once, saved or not")
    func writeInFlight() async throws {
        for releases in [true, false] {
            let service = try C.service()
            await service.setBeforeBackup { throw SkipBackup() }
            let gate = Gate()
            let event = C.event("inflight")
            await service.enqueue("held write") { repositories in
                try await gate.pass()
                _ = try await repositories.captures.record(event)
            }
            #expect(await gate.reached())
            if releases { Task { try? await Task.sleep(for: .milliseconds(150)); gate.open() } }
            let took = await C.elapsed(C.budget + C.tolerance) { await service.close() }
            defer { gate.open() }
            #expect(took != nil, "released: \(releases)")
            try? await Task.sleep(for: .milliseconds(200))
            let status = await service.status()
            #expect(status.written + status.failed + status.dropped == 1, "released: \(releases), \(status)")
            #expect(status.written == (releases ? 1 : 0), "released: \(releases)")
        }
    }

    @Test("two closes at once make one stop; a write offered during the close is refused and counted; no copy starts")
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
        gate.open()
        let took = await C.elapsed(C.budget + C.tolerance) { await first.value; await second.value }
        #expect(took != nil)
        let status = await service.status()
        #expect(status.written + status.failed + status.dropped == 2, "two offered, \(status)")
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

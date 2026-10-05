//
//  ProductionBudgetMeasures.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 04/10/2026.
//

@testable import AutomationRuntime
import EngineCore
import Foundation
import Memory
import SQLite3
import SQLiteMemory
import Testing

/// Measures the memory's budget after a stop with the service's production defaults (a 3 s budget per
/// stopped owner, the store's own lock cycles) on temporary archives, under a real SQLite lock another
/// connection holds. Before each stop it proves the owner's finalization is the one waiting: the lock is
/// taken, the store holds exactly one write (`retainedWrites`) and the owner has one finalization enrolled
/// (`waitingFinalizations`), so the stop reaches a finalization and not a first `planned` record. Prints one
/// `BUDGET-MEASURE` line per case (monotonic, from the stop) and checks structure with a margin wide
/// enough to tell one shared budget from one per fact: what was cut, what was saved once, that nothing is
/// retained, that the service stays ready, and the archive's integrity and foreign keys afterwards.
///
/// Enabled with `MECUM_MEASURE_PRODUCTION=1` only: each case waits on the order of the real budget.
@Suite("Measured: the memory's production budget after a stop, under a real lock", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MECUM_MEASURE_PRODUCTION"] == "1",
                "MECUM_MEASURE_PRODUCTION=1 runs the production budget, seconds per case"))
struct ProductionBudgetMeasures {

    private static var budget: Duration { MemoryService.Configuration().finalizationBudget }

    private static func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while await !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    private static func event(_ id: String, _ memory: MemoryService) -> MemoryEventRecord {
        Fixtures.context(id).event(app: Fixtures.app, occurredAtMS: memory.clock.calendarMS())
    }

    /// A batch of three steps planned as one write: the parent and its children in one transaction.
    private static func batch(_ id: String, _ memory: MemoryService) throws -> (AgentCallRecord, [AgentCallRecord]) {
        let context = Fixtures.context(id)
        let parent = try AgentCallRecord(event: context.event(app: Fixtures.app, occurredAtMS: memory.clock.calendarMS()), request: .batch)
        let steps = try (0..<3).map { position in
            try AgentCallRecord(event: context.child(position, eventID: "\(id)-\(position)")
                .event(app: Fixtures.app, occurredAtMS: memory.clock.calendarMS()),
                request: .act(target: "Export", verb: .click, value: nil, section: nil))
        }
        return (parent, steps)
    }

    /// The archive's integrity and foreign keys, read by a connection of its own once the service closed.
    private static func integrity(_ url: URL) -> (integrity: String, foreignKeyViolations: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = db else { return ("unopened", -1) }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        var result = "none"
        if sqlite3_prepare_v2(handle, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
            result = String(cString: sqlite3_column_text(statement, 0))
        }
        sqlite3_finalize(statement)
        var violations = 0
        if sqlite3_prepare_v2(handle, "PRAGMA foreign_key_check", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW { violations += 1 }
        }
        sqlite3_finalize(statement)
        return (result, violations)
    }

    /// One owner's two finalizations, a single fact then a batch of three steps, run one after the other
    /// in a task whose owner is `scope`. Answers which were saved.
    private static func writeAndBatch(_ memory: MemoryService, scope: MemoryFinalizationScope, prefix: String)
        -> Task<[String], Never> {
        Task {
            await MemoryFinalizationScope.$current.withValue(scope) {
                var saved: [String] = []
                if (try? await memory.finalize { try await memory.record(Self.event("\(prefix)-fact", memory)) }) == .committed {
                    saved.append("fact")
                }
                if let (parent, steps) = try? Self.batch("\(prefix)-batch", memory),
                   (try? await memory.finalize { try await memory.record(batch: parent, steps: steps) }) == .committed {
                    saved.append("batch")
                }
                return saved
            }
        }
    }

    @Test("a single fact and a batch of one owner, under a lock held past the stop: both cut, together after one budget, not two")
    func aFactAndABatchShareOneBudget() async throws {
        let memory = MemoryService(directory: Fixtures.directory())
        try await memory.open()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        let scope = MemoryFinalizationScope()
        let task = Self.writeAndBatch(memory, scope: scope, prefix: "held")
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 && scope.waitingFinalizations == 1 }
        let waiting = await memory.status().diagnostics?.retainedWrites == 1 && scope.waitingFinalizations == 1
        let stop = ContinuousClock.now
        scope.stop(at: stop)
        let saved = await task.value
        let elapsed = ContinuousClock.now - stop
        writer.release()
        let retained = await memory.status().diagnostics?.retainedWrites
        let ready = await memory.status().isReady
        let fact = try await memory.event("held-fact"), parent = try await memory.event("held-batch")
        await memory.close()
        let check = Self.integrity(memory.url)
        print("BUDGET-MEASURE case=fact-and-batch-lock-held budgetMs=\(Self.ms(Self.budget)) waitingBeforeStop=\(waiting) "
              + "stopToEndMs=\(Self.ms(elapsed)) saved=\(saved) retained=\(retained.map(String.init) ?? "-") ready=\(ready) "
              + "integrity=\(check.integrity) fkViolations=\(check.foreignKeyViolations)")
        #expect(waiting, "the owner's finalization was waiting on the lock before the stop")
        #expect(saved.isEmpty, "both facts cut: \(saved)")
        #expect(elapsed >= Self.budget, "the budget is spent before anything is cut")
        #expect(elapsed < Self.budget * 2, "one shared budget for the fact and the batch, where one each would take two")
        #expect(fact == nil && parent == nil, "a cut fact is not on disk")
        #expect(retained == 0 && ready, "nothing retained; a stop is not a degradation")
        #expect(check.integrity == "ok" && check.foreignKeyViolations == 0)
    }

    @Test("a single fact and a batch of one owner, the lock released within what is left of the budget: both saved, once")
    func aReleaseWithinTheBudgetSavesBoth() async throws {
        let memory = MemoryService(directory: Fixtures.directory())
        try await memory.open()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        let scope = MemoryFinalizationScope()
        let task = Self.writeAndBatch(memory, scope: scope, prefix: "released")
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 && scope.waitingFinalizations == 1 }
        let waiting = await memory.status().diagnostics?.retainedWrites == 1 && scope.waitingFinalizations == 1
        let stop = ContinuousClock.now
        scope.stop(at: stop)
        try await Task.sleep(for: Self.budget / 3)
        writer.release()
        let saved = await task.value
        let elapsed = ContinuousClock.now - stop
        let commits = await memory.status().diagnostics?.commits
        let fact = try await memory.event("released-fact"), parent = try await memory.event("released-batch")
        var steps = 0
        for position in 0..<3 where try await memory.event("released-batch-\(position)") != nil { steps += 1 }
        await memory.close()
        let check = Self.integrity(memory.url)
        print("BUDGET-MEASURE case=fact-and-batch-released-within-budget budgetMs=\(Self.ms(Self.budget)) waitingBeforeStop=\(waiting) "
              + "releaseAfterStopMs=\(Self.ms(Self.budget / 3)) stopToEndMs=\(Self.ms(elapsed)) saved=\(saved) commits=\(commits.map(String.init) ?? "-") "
              + "batchSteps=\(steps) integrity=\(check.integrity) fkViolations=\(check.foreignKeyViolations)")
        #expect(waiting)
        #expect(saved == ["fact", "batch"])
        #expect(commits == 2, "the fact once, the batch once: nothing written twice")
        #expect(fact != nil && parent != nil && steps == 3)
        #expect(elapsed < Self.budget, "saved before the deadline")
        #expect(check.integrity == "ok" && check.foreignKeyViolations == 0)
    }

    @Test("another owner on the same service, waiting on the same lock, is not stopped by the first owner's stop: it saves once the lock goes")
    func anotherOwnerKeepsWaiting() async throws {
        let memory = MemoryService(directory: Fixtures.directory())
        try await memory.open()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        let first = MemoryFinalizationScope(), second = MemoryFinalizationScope()
        let stopped = Task {
            await MemoryFinalizationScope.$current.withValue(first) {
                (try? await memory.finalize { try await memory.record(Self.event("first-owner", memory)) }) == .committed
            }
        }
        let other = Task {
            await MemoryFinalizationScope.$current.withValue(second) {
                (try? await memory.finalize { try await memory.record(Self.event("second-owner", memory)) }) == .committed
            }
        }
        await Self.until {
            await memory.status().diagnostics?.retainedWrites == 2 && first.waitingFinalizations == 1 && second.waitingFinalizations == 1
        }
        let waiting = await memory.status().diagnostics?.retainedWrites == 2
        let stop = ContinuousClock.now
        first.stop(at: stop)
        let firstSaved = await stopped.value
        let firstElapsed = ContinuousClock.now - stop
        let otherStillWaiting = await memory.status().diagnostics?.retainedWrites == 1 && second.stopInstant == nil
        // Past the first owner's whole budget, the other owner is still waiting; then the lock goes.
        try await Task.sleep(for: .milliseconds(500))
        writer.release()
        let otherSaved = await other.value
        let commits = await memory.status().diagnostics?.commits
        await memory.close()
        let check = Self.integrity(memory.url)
        print("BUDGET-MEASURE case=another-owner budgetMs=\(Self.ms(Self.budget)) waitingBeforeStop=\(waiting) "
              + "firstStopToEndMs=\(Self.ms(firstElapsed)) firstSaved=\(firstSaved) otherStillWaitingAfterFirstCut=\(otherStillWaiting) "
              + "otherSaved=\(otherSaved) commits=\(commits.map(String.init) ?? "-") integrity=\(check.integrity) fkViolations=\(check.foreignKeyViolations)")
        #expect(waiting)
        #expect(!firstSaved && firstElapsed >= Self.budget && firstElapsed < Self.budget * 2)
        #expect(otherStillWaiting, "the other owner's write is still offered after the first one is cut")
        #expect(otherSaved && commits == 1)
        #expect(check.integrity == "ok" && check.foreignKeyViolations == 0)
    }
}

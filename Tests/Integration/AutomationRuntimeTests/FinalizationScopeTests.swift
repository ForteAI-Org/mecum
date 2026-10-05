//
//  FinalizationScopeTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

@testable import AutomationRuntime
import Foundation
import Memory
import SQLiteMemory
import Synchronization
import Testing

/// One budget of the memory per stopped owner: the rule on its own, with chosen instants, then through
/// the service with a lock another connection holds. Timings are asserted only as structure with a wide
/// margin (one shared budget against one per fact), never as a tight wall-clock ceiling.
@Suite("One finalization budget per stopped owner", .serialized)
struct FinalizationScopeTests {

    private static let budget = Duration.milliseconds(300)

    private static func service() -> MemoryService {
        MemoryService(directory: Fixtures.directory(), configuration: .init(
            store: .init(lockBudget: .milliseconds(20), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(5)),
            finalizationBudget: budget
        ))
    }

    private static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    private static func event(_ id: String, _ memory: MemoryService) -> MemoryEventRecord {
        Fixtures.context(id).event(app: Fixtures.app, occurredAtMS: memory.clock.calendarMS())
    }

    // MARK: The rule

    @Test("the rule: the first stop is kept, every deadline is that stop plus the budget, a later stop moves nothing")
    func theRuleOnItsOwn() {
        let scope = MemoryFinalizationScope()
        let t0 = ContinuousClock.now
        #expect(scope.stopInstant == nil)
        #expect(scope.deadline(budget: .seconds(3), stoppingAt: t0) == t0 + .seconds(3), "the first observation is the stop")
        #expect(scope.deadline(budget: .seconds(3), stoppingAt: t0 + .seconds(1)) == t0 + .seconds(3), "a later finalization opens no new budget")
        scope.stop(at: t0 + .seconds(2))
        #expect(scope.stopInstant == t0, "a later stop moves nothing")
        let said = MemoryFinalizationScope()
        said.stop(at: t0)
        #expect(said.deadline(budget: .seconds(3), stoppingAt: t0 + .seconds(5)) == t0 + .seconds(3), "the owner's stop, not the finalization's instant")
    }

    @Test("a caller cancelled after its owner's deadline gets a gap at once and its body never runs")
    func anExpiredOwnerOffersNothing() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        scope.stop(at: .now - .seconds(10))
        let ran = Mutex(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await MemoryFinalizationScope.$current.withValue(scope) {
                await #expect(throws: CancellationError.self) {
                    _ = try await memory.finalize { ran.withLock { $0 = true }; return 1 }
                }
            }
        }
        await task.value
        #expect(!ran.withLock { $0 }, "nothing offered once the budget is spent")
        await memory.close()
    }

    // Before the S4 loop correction this test used a stopped owner whose budget was spent and expected no
    // bound: it encoded the defect, a stop that never reached a caller whose task was not cancelled. The
    // requirement it stands for is ordinary work: an owner not stopped and a caller not cancelled.
    @Test("ordinary work, an owner not stopped and a caller not cancelled, is bounded by nothing: it waits past any budget and saves once")
    func ordinaryWorkIsNeverBounded() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        let saving = Task {
            try await MemoryFinalizationScope.$current.withValue(scope) {
                try await memory.finalize { try await memory.record(Self.event("ordinary", memory)) }
            }
        }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 }
        try await Task.sleep(for: Self.budget * 2)
        #expect(await memory.status().diagnostics?.retainedWrites == 1, "still waiting, past any budget")
        #expect(scope.stopInstant == nil)
        writer.release()
        #expect(try await saving.value == .committed)
        #expect(await memory.status().diagnostics?.commits == 1)
        #expect(scope.waitingFinalizations == 0, "nothing left enrolled")
        await memory.close()
    }

    @Test("an owner stopped before the finalization bounds it although the caller's task is not cancelled")
    func aStopBeforeBoundsACallerStillRunning() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        defer { writer.release() }
        let stop = ContinuousClock.now
        scope.stop(at: stop)
        let task = Task {
            await MemoryFinalizationScope.$current.withValue(scope) {
                await #expect(throws: (any Error).self) { _ = try await memory.finalize { try await memory.record(Self.event("late", memory)) } }
            }
        }
        await task.value
        let elapsed = ContinuousClock.now - stop
        #expect(!task.isCancelled, "the caller's task ran on: the stop alone bounded it")
        #expect(elapsed >= Self.budget && elapsed < Self.budget * 2, "until the owner's deadline")
        #expect(scope.waitingFinalizations == 0)
        await memory.close()
    }

    @Test("an owner stopped while a finalization waits reaches it, the caller's task not cancelled: cut at the stop plus the budget")
    func aStopReachesAWaitingFinalization() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        defer { writer.release() }
        let task = Task {
            await MemoryFinalizationScope.$current.withValue(scope) {
                await #expect(throws: (any Error).self) { _ = try await memory.finalize { try await memory.record(Self.event("waiting", memory)) } }
            }
        }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 }
        #expect(scope.waitingFinalizations == 1, "enrolled with its owner while it waits")
        let stop = ContinuousClock.now
        scope.stop(at: stop)
        await task.value
        let elapsed = ContinuousClock.now - stop
        #expect(elapsed >= Self.budget && elapsed < Self.budget * 2)
        #expect(scope.waitingFinalizations == 0, "withdrawn once ended")
        #expect(await memory.status().diagnostics?.retainedWrites == 0)
        await memory.close()
    }

    @Test("a finalization offered after its stopped owner's deadline, the caller not cancelled, is a gap at once and its body never runs")
    func anExpiredOwnerOffersNothingToARunningCaller() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        scope.stop(at: .now - .seconds(10))
        let ran = Mutex(false)
        try await MemoryFinalizationScope.$current.withValue(scope) {
            await #expect(throws: CancellationError.self) {
                _ = try await memory.finalize { ran.withLock { $0 = true }; return 1 }
            }
        }
        #expect(!ran.withLock { $0 })
        #expect(scope.waitingFinalizations == 0)
        await memory.close()
    }

    @Test("a stop racing twenty finalizations that start around it: one deadline for all, none outlives it, none left enrolled")
    func aStopRacingManyFinalizations() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        defer { writer.release() }
        let stop = ContinuousClock.now + .milliseconds(5)
        let ended = try await withThrowingTaskGroup(of: ContinuousClock.Instant.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(index / 2))
                    _ = try? await MemoryFinalizationScope.$current.withValue(scope) {
                        try await memory.finalize { try await memory.record(Self.event("race-\(index)", memory)) }
                    }
                    return ContinuousClock.now
                }
            }
            try await Task.sleep(until: stop, clock: .continuous)
            scope.stop(at: stop)
            var ends: [ContinuousClock.Instant] = []
            for try await end in group { ends.append(end) }
            return ends
        }
        #expect(ended.count == 20)
        #expect(ended.allSatisfy { $0 < stop + Self.budget * 2 }, "none waits past the one deadline, with margin")
        #expect(scope.waitingFinalizations == 0)
        #expect(await memory.status().diagnostics?.retainedWrites == 0)
        await memory.close()
    }

    @Test("the cancellation of one caller's task stops its owner: a sibling finalization not cancelled is bounded by the same deadline")
    func aCancellationStopsTheOwner() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        defer { writer.release() }
        let sibling = Task {
            await MemoryFinalizationScope.$current.withValue(scope) {
                await #expect(throws: (any Error).self) { _ = try await memory.finalize { try await memory.record(Self.event("sibling", memory)) } }
            }
        }
        let cancelled = Task {
            await MemoryFinalizationScope.$current.withValue(scope) {
                await #expect(throws: (any Error).self) { _ = try await memory.finalize { try await memory.record(Self.event("cancelled", memory)) } }
            }
        }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 2 }
        cancelled.cancel()
        await cancelled.value
        await sibling.value
        let stopped = try #require(scope.stopInstant, "the cancellation said the owner's stop")
        #expect(ContinuousClock.now - stopped < Self.budget * 2)
        #expect(scope.waitingFinalizations == 0)
        await memory.close()
    }

    // MARK: Through the service

    /// Five finalizations of one owner, one after the other, under a lock that never goes, the owner
    /// stopped during the first: answers how many were cut and how long from the stop to the end.
    private func fiveFinalizations(in memory: MemoryService, scope: MemoryFinalizationScope)
        async throws -> (cut: Int, elapsed: Duration) {
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        defer { writer.release() }
        let task = Task { () -> Int in
            await MemoryFinalizationScope.$current.withValue(scope) {
                var cut = 0
                for index in 0..<5 {
                    do { _ = try await memory.finalize { try await memory.record(Self.event("fact-\(index)", memory)) } }
                    catch { if MemoryService.isCancellation(error) { cut += 1 } }
                }
                return cut
            }
        }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 }
        let stop = ContinuousClock.now
        scope.stop(at: stop)
        task.cancel()
        let cut = await task.value
        return (cut, ContinuousClock.now - stop)
    }

    @Test("five finalizations of one stopped owner share one budget: all cut, the whole after about one budget, not five")
    func aStoppedOwnerSharesOneBudget() async throws {
        let memory = Self.service()
        try await memory.open()
        let (cut, elapsed) = try await fiveFinalizations(in: memory, scope: MemoryFinalizationScope())
        print("SCOPE-MEASURE case=five-finalizations budgetMs=\(Self.budget.components.attoseconds / 1_000_000_000_000_000) "
              + "stopToEndMs=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) cut=\(cut)")
        #expect(cut == 5)
        #expect(elapsed >= Self.budget, "the budget is spent before anything is cut")
        #expect(elapsed < Self.budget * 2, "one shared budget, where one each would take five")
        #expect(try await memory.event("fact-0") == nil)
        #expect(await memory.status().isReady, "a stop degrades nothing")
        await memory.close()
    }

    @Test("a lock released within the budget after the stop: every fact of the owner saved, once")
    func aReleaseWithinTheBudgetSavesTheOwnersFacts() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        let task = Task { () -> Int in
            await MemoryFinalizationScope.$current.withValue(scope) {
                var saved = 0
                for index in 0..<3 {
                    if (try? await memory.finalize { try await memory.record(Self.event("kept-\(index)", memory)) }) == .committed { saved += 1 }
                }
                return saved
            }
        }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 }
        scope.stop()
        task.cancel()
        try await Task.sleep(for: Self.budget / 3)
        writer.release()
        #expect(await task.value == 3)
        #expect(await memory.status().diagnostics?.commits == 3, "each fact once")
        await memory.close()
    }

    @Test("another owner on the same service is not abandoned: it keeps waiting, then saves; stopped later, it has a budget of its own")
    func anotherOwnerIsNotAbandoned() async throws {
        let memory = Self.service()
        try await memory.open()
        let first = MemoryFinalizationScope(), second = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        let stopped = Task {
            await MemoryFinalizationScope.$current.withValue(first) {
                await #expect(throws: (any Error).self) { _ = try await memory.finalize { try await memory.record(Self.event("first", memory)) } }
            }
        }
        let other = Task {
            try await MemoryFinalizationScope.$current.withValue(second) {
                try await memory.finalize { try await memory.record(Self.event("second", memory)) }
            }
        }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 2 }
        first.stop()
        stopped.cancel()
        await stopped.value
        #expect(await memory.status().diagnostics?.retainedWrites == 1, "the other owner's write is still offered")
        #expect(second.stopInstant == nil)
        writer.release()
        #expect(try await other.value == .committed)
        let first0 = try await memory.event("first"), second0 = try await memory.event("second")
        #expect(first0 == nil && second0 != nil)

        // The second owner stopped later has its own whole budget.
        let again = try ExternalWriter(memory.url)
        again.lock()
        let later = Task {
            await MemoryFinalizationScope.$current.withValue(second) {
                await #expect(throws: (any Error).self) { _ = try await memory.finalize { try await memory.record(Self.event("later", memory)) } }
            }
        }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 }
        let stop = ContinuousClock.now
        second.stop(at: stop)
        later.cancel()
        await later.value
        #expect(ContinuousClock.now - stop >= Self.budget, "a budget of its own, not the first owner's spent one")
        again.release()
        await memory.close()
    }

    @Test("a caller already cancelled sets one deadline for its owner, at its first finalization, not one per fact")
    func anAlreadyCancelledCallerSetsOneDeadline() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        defer { writer.release() }
        let start = ContinuousClock.now
        let task = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return await MemoryFinalizationScope.$current.withValue(scope) {
                var cut = 0
                for index in 0..<4 {
                    do { _ = try await memory.finalize { try await memory.record(Self.event("late-\(index)", memory)) } }
                    catch { if MemoryService.isCancellation(error) { cut += 1 } }
                }
                return cut
            }
        }
        #expect(await task.value == 4)
        let elapsed = ContinuousClock.now - start
        #expect(scope.stopInstant != nil, "the first cancelled finalization said the stop")
        #expect(elapsed >= Self.budget && elapsed < Self.budget * 2, "one deadline for the four")
        await memory.close()
    }

    @Test("close is not a flush: a stopped owner's finalization ends at once as closed, without spending its budget")
    func closeAfterTheStopIsNotAFlush() async throws {
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        defer { writer.release() }
        let task = Task {
            await MemoryFinalizationScope.$current.withValue(scope) {
                await #expect(throws: (any Error).self) { _ = try await memory.finalize { try await memory.record(Self.event("closing", memory)) } }
            }
        }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 }
        let stop = ContinuousClock.now
        scope.stop(at: stop)
        task.cancel()
        await memory.close()
        await task.value
        #expect(ContinuousClock.now - stop < Self.budget, "the close ended the wait; nothing was flushed")
        writer.release()
        let reader = MemoryService(directory: memory.directory)
        #expect(try await reader.event("closing") == nil)
        await reader.close()
    }

    // MARK: The opt-in trace

    /// The trace's lines of one owner: each as its step and its fields.
    private static func traced(_ file: URL, owner: Int) -> [(step: String, fields: [String: String])] {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ")
            guard let step = words.first else { return nil }
            let fields = Dictionary(words.dropFirst().compactMap { word -> (String, String)? in
                let pair = word.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { $1 })
            return fields["owner"] == "\(owner)" ? (String(step), fields) : nil
        }
    }

    @Test("the opt-in trace is off by default; on, it says the owner's finalization waiting under the lock, the stop, the cut at the deadline, the gap and a later refusal, on the monotonic clocks")
    func theTraceSaysTheWaitTheStopAndTheCut() async throws {
        FinalizationTrace.record(to: nil)
        #expect(MemoryFinalizationScope().traceNumber == nil, "off unless asked for")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("finalization-trace-\(UUID().uuidString).txt")
        FinalizationTrace.record(to: file.path)
        defer {
            FinalizationTrace.record(to: nil)
            try? FileManager.default.removeItem(at: file)
        }
        let memory = Self.service()
        try await memory.open()
        let scope = MemoryFinalizationScope()
        let owner = try #require(scope.traceNumber)
        let writer = try ExternalWriter(memory.url)
        writer.lock()
        defer { writer.release() }
        let task = Task {
            await MemoryFinalizationScope.$current.withValue(scope) {
                await #expect(throws: (any Error).self) { _ = try await memory.finalize { try await memory.record(Self.event("traced", memory)) } }
            }
        }
        await Self.until { Self.traced(file, owner: owner).contains { $0.step == "waiting" } }
        scope.stop()
        await task.value
        try await MemoryFinalizationScope.$current.withValue(scope) {
            try await Task.sleep(for: Self.budget)
            await #expect(throws: CancellationError.self) { _ = try await memory.finalize { 1 } }
        }
        let all = Self.traced(file, owner: owner)
        #expect(all.contains { $0.step == "cycle" }, "the test's lock budgets of 20 ms run out while it waits")
        let lines = all.filter { $0.step != "cycle" }
        #expect(lines.map(\.step) == ["offered", "waiting", "stopped", "cut", "ended", "refused"])
        #expect(lines.first { $0.step == "waiting" }?.fields["phase"] != nil)
        #expect(lines.first { $0.step == "stopped" }?.fields["waiting"] == "1", "the stop found it waiting")
        #expect(lines.first { $0.step == "ended" }?.fields["outcome"] == "gap")
        #expect(Set(lines.compactMap { $0.fields["pid"] }) == ["\(getpid())"])
        let continuous = lines.map { Int64($0.fields["continuous_ns"] ?? "") ?? -1 }
        #expect(continuous == continuous.sorted() && !continuous.contains(-1), "in the order they happened")
        try #require(continuous.count == 6)
        let stopped = continuous[2], cut = continuous[3]
        let budget = Int64(Self.budget.components.seconds) * 1_000_000_000 + Self.budget.components.attoseconds / 1_000_000_000
        #expect(cut - stopped >= budget && cut - stopped < 2 * budget, "cut at the stop plus the budget")
        await memory.close()
    }
}

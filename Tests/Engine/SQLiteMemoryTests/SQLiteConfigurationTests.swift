//
//  SQLiteConfigurationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The waiting policy cannot let the store retry without pausing: a configuration that would is
/// refused before anything is opened, and the smallest accepted one still pauses once per cycle.
@Suite("The waiting policy's limits")
struct SQLiteConfigurationTests {

    @Test("the defaults are accepted")
    func defaults() {
        #expect(SQLiteMemoryStore.Configuration().problem == nil)
    }

    @Test("a policy that would allow a retry without a pause is refused at open, and nothing is created")
    func refusals() async throws {
        let refused: [SQLiteMemoryStore.Configuration] = [
            .init(retryPause: .zero),
            .init(retryPause: .milliseconds(-5)),
            .init(retryPause: .milliseconds(10), maximumRetryPause: .milliseconds(5)),
            .init(lockBudget: .milliseconds(4), retryPause: .milliseconds(5)),
            .init(snapshotPagesPerStep: 0),
        ]
        for configuration in refused {
            #expect(configuration.problem != nil)
            let url   = try temporaryDatabase()
            let store = SQLiteMemoryStore(url: url, configuration: configuration)
            let error = await storeError { try await store.open() }
            guard case .unavailable(.misconfigured(let problem))? = error else {
                Issue.record("expected misconfigured, got \(String(describing: error))")
                continue
            }
            #expect(problem == configuration.problem)
            #expect(await store.liveHandles == 0)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        let accepted = SQLiteMemoryStore.Configuration(lockBudget: .milliseconds(5), retryPause: .milliseconds(5), maximumRetryPause: .milliseconds(5))
        #expect(accepted.problem == nil)
    }

    /// Runs one cycle of the waiting rule with every attempt busy, each pause lasting what
    /// `lasted` answers for it: the pauses asked for, in order, and the cycle at its end.
    private func schedule(
        _ configuration: SQLiteMemoryStore.Configuration,
        lasted: (Int, Duration) -> Duration = { $1 }
    ) -> (pauses: [Duration], cycle: SQLiteMemoryStore.WaitingCycle) {
        var cycle  = SQLiteMemoryStore.WaitingCycle(configuration)
        var pauses: [Duration] = []
        while true {
            cycle.attempting()
            guard let pause = cycle.nextPause else { return (pauses, cycle) }
            pauses.append(pause)
            cycle.paused(for: lasted(pauses.count, pause))
        }
    }

    @Test("the waiting rule on its own: the pause doubles from retryPause up to the maximum, and the cycle ends at the first pause that would overrun the budget, whatever each pause really lasted")
    func waitingSchedule() {
        let policy = SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(150), retryPause: .milliseconds(5), maximumRetryPause: .milliseconds(20)
        )
        let punctual = schedule(policy)
        #expect(punctual.pauses == [5, 10, 20, 20, 20, 20, 20, 20].map { .milliseconds($0) })
        #expect(punctual.cycle.attempts == 9 && punctual.cycle.waited == .milliseconds(135))
        #expect(punctual.cycle.pause == .milliseconds(20), "the next pause, 20 ms, would make 155 ms")

        // What the full runs met: the first 5 ms pause outlasted most of the budget, so the cycle
        // ended after two attempts and one pause, and waited past any fixed ceiling.
        for first in [146, 469] {
            let late = schedule(policy) { index, pause in index == 1 ? .milliseconds(first) : pause }
            #expect(late.pauses == [.milliseconds(5)])
            #expect(late.cycle.attempts == 2 && late.cycle.waited == .milliseconds(first))
        }
        let edge = schedule(policy) { index, pause in index == 1 ? .milliseconds(140) : pause }
        #expect(edge.pauses == [.milliseconds(5), .milliseconds(10)], "140 + 10 is still within 150 ms")

        // Every accepted policy takes a first pause, and every cycle ends, however short its pauses.
        for budget in [5, 6, 150, 2_000] {
            let accepted = SQLiteMemoryStore.Configuration(
                lockBudget: .milliseconds(budget), retryPause: .milliseconds(5), maximumRetryPause: .milliseconds(100)
            )
            #expect(accepted.problem == nil)
            let run = schedule(accepted)
            #expect(run.pauses.first == .milliseconds(5))
            #expect(run.cycle.attempts == run.pauses.count + 1)
            #expect(run.cycle.waited <= accepted.lockBudget)
            #expect(run.cycle.waited + run.cycle.pause > accepted.lockBudget)
        }

        var cancelled = SQLiteMemoryStore.WaitingCycle(policy)
        cancelled.attempting()
        cancelled.interrupted(after: .milliseconds(3))
        #expect(cancelled.waited == .milliseconds(3) && cancelled.pause == .milliseconds(5), "a cut pause counts as waited and doubles nothing")
    }

    @Test("the smallest accepted budget still pauses once in every cycle: no cycle ends without waiting")
    func minimalBudgetPauses() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url, configuration: SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(5), retryPause: .milliseconds(5), maximumRetryPause: .milliseconds(5)
        ))
        var events = await waits(of: store)
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")

        let started  = ContinuousClock.now
        let producer = Task { await storeError { _ = try await record(EventRow(id: "act-1", key: "k1"), in: store) } }
        var sequence: [SQLiteMemoryStore.WaitEvent] = []
        var exhausted = 0
        while exhausted < 4, let event = await events.next() {
            sequence.append(event)
            if case .cycleExhausted = event { exhausted += 1 }
        }
        let elapsed = ContinuousClock.now - started
        // Every spent budget was preceded by a real pause, and held exactly one pause: two attempts.
        var pausesSinceLastCycle = 0
        for event in sequence {
            switch event {
            case .pausing:
                pausesSinceLastCycle += 1
            case .cycleExhausted(let phase, let attempts, let waited):
                #expect(phase == .begin)
                #expect(attempts == 2)
                #expect(waited >= .milliseconds(5))
                #expect(pausesSinceLastCycle == 1)
                pausesSinceLastCycle = 0
            case .yielding:
                Issue.record("no yield expected while waiting for a lock")
            }
        }
        #expect(elapsed >= .milliseconds(20))
        let waiting = try await store.diagnostics()
        #expect(waiting.busyRetries >= 4)
        #expect(waiting.exhaustedCycles >= 4)
        #expect(waiting.retainedWrites == 1)

        try holder.execute("ROLLBACK")
        holder.close()
        #expect(await producer.value == nil)
        #expect(try await store.diagnostics().commits == 1)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 1)
        await store.close()
    }
}

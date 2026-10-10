//
//  PendingRetryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import AutomationRuntime
import Foundation
import Memory
import Testing

/// PendingRetryTests prove how the facts kept after an effect are retried when several producers want
/// to start at once (review F01 of plan D1): one retry for all of them, each fact saved once and in
/// order, the suspension kept while one still fails and lifted only once none is left, and a close in
/// the middle of a retry that leaves the process running.
@Suite("Retrying the kept facts while several producers start")
struct PendingRetryTests {

    /// Script answers each offer of a labelled fact as the test planned it, in order: a failure the
    /// archive may recover from, a hold until the test releases it, or a save. It records every offer
    /// and every save.
    actor Script {
        enum Step { case fail, hold, save }

        private var steps: [String: [Step]]
        private(set) var offers: [String] = []
        private(set) var saved: [String] = []
        private var held: [CheckedContinuation<Void, Never>] = []
        private var holdWaiters: [CheckedContinuation<Void, Never>] = []

        init(_ steps: [String: [Step]]) { self.steps = steps }

        func offer(_ label: String) async throws {
            offers.append(label)
            var planned = steps[label] ?? []
            let step = planned.isEmpty ? Step.save : planned.removeFirst()
            steps[label] = planned
            switch step {
                case .fail:
                    throw EssentialWriteFailure.storageFull("scripted")
                case .hold:
                    await withCheckedContinuation { continuation in
                        held.append(continuation)
                        holdWaiters.forEach { $0.resume() }
                        holdWaiters = []
                    }
                    saved.append(label)
                case .save:
                    saved.append(label)
            }
        }

        /// Waits until an offer is held.
        func untilHeld() async {
            guard held.isEmpty else { return }
            await withCheckedContinuation { holdWaiters.append($0) }
        }

        func release() {
            held.forEach { $0.resume() }
            held = []
        }
    }

    private func memory() -> MemoryService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-retry-\(UUID().uuidString)", isDirectory: true)
        return MemoryService(directory: directory, configuration: .init(essentialAttempts: 1))
    }

    /// Keeps `label` after an effect: its first offer fails, so the service is suspended with it.
    private func keep(_ label: String, in memory: MemoryService, _ script: Script) async throws {
        await #expect(throws: EssentialWriteFailure.self) {
            try await memory.confirm(label, afterEffect: true) { _ in try await script.offer(label) }
        }
    }

    @Test("two producers that find the memory suspended wait for one retry: the kept end is saved once, both start, the suspension lifts")
    func twoProducersOneRetry() async throws {
        let memory = memory()
        let script = Script(["end": [.fail, .hold]])
        try await keep("end", in: memory, script)
        #expect(await memory.status().pendingEssential == 1)

        async let first = memory.confirm("start A", beforeEffect: true) { _ in try await script.offer("start A") }
        await script.untilHeld()
        async let second = memory.confirm("start B", beforeEffect: true) { _ in try await script.offer("start B") }
        // The second start finds the retry in progress and waits for it instead of offering the end again.
        try await Task.sleep(for: .milliseconds(100))
        await script.release()
        _ = try await (first, second)

        #expect(await script.offers.filter { $0 == "end" }.count == 2, "the failed offer and the one retry")
        #expect(await script.saved.filter { $0 == "end" } == ["end"])
        #expect(Set(await script.saved) == ["end", "start A", "start B"])
        let status = await memory.status()
        #expect(status.suspended == nil && status.pendingEssential == 0)
        await memory.close()
    }

    @Test("several kept facts are retried in order; one still failing keeps the memory suspended for every producer, and a later start saves the rest once")
    func severalKeptFactsAndAFailingRetry() async throws {
        let memory = memory()
        let script = Script(["end 1": [.fail, .save], "end 2": [.fail, .fail, .save], "end 3": [.fail, .save]])
        for label in ["end 1", "end 2", "end 3"] { try await keep(label, in: memory, script) }
        #expect(await memory.status().pendingEssential == 3)

        async let first = memory.confirm("start A", beforeEffect: true) { _ in try await script.offer("start A") }
        async let second = memory.confirm("start B", beforeEffect: true) { _ in try await script.offer("start B") }
        var refused = 0
        do { _ = try await first } catch EssentialWriteFailure.suspended { refused += 1 }
        do { _ = try await second } catch EssentialWriteFailure.suspended { refused += 1 }
        #expect(refused == 2, "no start goes on while a kept fact still fails")
        var status = await memory.status()
        #expect(status.pendingEssential == 2 && status.suspended?.contains("end 2") == true)
        #expect(await script.saved == ["end 1"], "no start ran, and the first end was saved once")

        _ = try await memory.confirm("start C", beforeEffect: true) { _ in try await script.offer("start C") }
        #expect(await script.saved == ["end 1", "end 2", "end 3", "start C"])
        status = await memory.status()
        #expect(status.suspended == nil && status.pendingEssential == 0)
        await memory.close()
    }

    @Test("a close while a retry is held ends the waiting starts without stopping the process; the unsaved end is counted")
    func closeDuringRetry() async throws {
        let memory = memory()
        let script = Script(["end": [.fail, .hold]])
        try await keep("end", in: memory, script)
        async let start = memory.confirm("start", beforeEffect: true) { _ in try await script.offer("start") }
        await script.untilHeld()
        async let closing: Void = memory.close()
        try await Task.sleep(for: .milliseconds(50))
        await script.release()
        await closing
        // Whatever the start answers once the memory closed, it never ran.
        _ = try? await start
        #expect(await !script.saved.contains("start"))
        #expect(await memory.status().lastClose != nil)
    }
}

//
//  StopFinalizationMeasures.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

/// Measures, on temporary archives, how long one call's recorder takes to finish once its task is
/// stopped while another writer holds the archive: the call is one owner (`MemoryFinalizationScope`),
/// so every finalization it still has to write spends the same budget from the stop, and the total is
/// one budget, not a sum. Every case prints
/// one `STOP-MEASURE` line (durations from the monotonic clock, from the stop to the recorder's return)
/// and checks the structure: how many facts were cut, how many were saved, that nothing is retained
/// and that the service stays ready. The budget is 100 ms unless `MECUM_MEASURE_FINALIZATION_MS` says
/// otherwise; with `MECUM_MEASURE_PRODUCTION=1` the service runs with its production defaults (2 s
/// lock cycle, 3 s budget). A synthetic recorder, no seat, no provider, no desktop.
@MainActor
@Suite("Measured: a recorder's finalizations after a stop", .serialized)
struct StopFinalizationMeasures {

    private static let environment = ProcessInfo.processInfo.environment

    private static var configuration: MemoryService.Configuration {
        if environment["MECUM_MEASURE_PRODUCTION"] == "1" { return MemoryService.Configuration() }
        let budget = environment["MECUM_MEASURE_FINALIZATION_MS"].flatMap(Int.init) ?? 100
        return MemoryService.Configuration(
            store: .init(lockBudget: .milliseconds(20), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(5)),
            finalizationBudget: .milliseconds(budget)
        )
    }

    private static var budgetMS: Int64 { configuration.finalizationBudget.components.seconds * 1000
        + configuration.finalizationBudget.components.attoseconds / 1_000_000_000_000_000 }

    private static func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while await !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    private struct Composed {
        let memory: MemoryService
        let recorder: CallRecorder
        let writer: ExternalWriter
    }

    private func composed(_ request: AgentCallRequest, _ eventID: String) async throws -> Composed {
        let memory  = MemoryService(directory: Fixtures.directory(), configuration: Self.configuration)
        let context = Fixtures.context(eventID)
        try await Fixtures.plan(request, context, in: memory)
        let clock = memory.clock
        let brain = BrainMemory(brains: memory, applications: memory, clock: { clock.brainNow() })
        let recorder = CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: 1,
                                    requestedAt: clock.brainNow())
        return Composed(memory: memory, recorder: recorder, writer: try ExternalWriter(memory.url))
    }

    private func action(_ eventID: String) -> ActionRecord {
        let before = Fixtures.window(["Export", "Platform"])
        let after  = Fixtures.window(["Export", "Platform", "Desktop", "Mobile"], surface: .popupUnion)
        return ActionRecord(bundleID: Fixtures.bundle, element: before.scene.elements[1], verb: .click,
                            effect: .menuOpened(labels: ["Desktop", "Mobile"]), windowTitleAfter: after.scene.windowTitle,
                            before: before, after: after, attempt: .delivered)
    }

    /// Runs `work` in a task, stops it once the store holds its first write, optionally lets the
    /// other writer go `releaseAfter` the stop, and answers the stop-to-return duration.
    private func stopped(
        _ made: Composed, releaseAfter: Duration?, closeAfterStop: Bool = false,
        _ work: @escaping @MainActor () async -> CallRecorder.Report
    ) async -> (report: CallRecorder.Report, stopToEnd: Duration) {
        made.writer.lock()
        let scope = MemoryFinalizationScope()
        let task = Task { @MainActor in await MemoryFinalizationScope.$current.withValue(scope) { await work() } }
        await Self.until { await made.memory.status().diagnostics?.retainedWrites == 1 }
        let stop = ContinuousClock.now
        scope.stop(at: stop)
        task.cancel()
        if closeAfterStop { await made.memory.close() }
        let release = releaseAfter.map { delay in Task { @MainActor in
            try? await Task.sleep(for: delay)
            made.writer.release()
        } }
        let report = await task.value
        let elapsed = ContinuousClock.now - stop
        await release?.value
        made.writer.release()
        return (report, elapsed)
    }

    private func emit(_ name: String, _ elapsed: Duration, _ report: CallRecorder.Report, _ memory: MemoryService) async {
        let status = await memory.status()
        print("STOP-MEASURE case=\(name) budgetMs=\(Self.budgetMS) stopToReturnMs=\(Self.ms(elapsed)) "
              + "cut=\(report.notes.count) samples=\(report.samples.map(\.rawValue)) "
              + "commits=\(status.diagnostics.map { String($0.commits) } ?? "closed") "
              + "retained=\(status.diagnostics.map { String($0.retainedWrites) } ?? "closed") "
              + "state=\(status.state) notes=\(report.notes)")
    }

    @Test("an observation stopped under a lock that never goes: one fact cut after one budget, nothing retained")
    func observationUnderAPermanentLock() async throws {
        let made = try await composed(.observe, "measure-observe")
        let (report, elapsed) = await stopped(made, releaseAfter: nil) {
            _ = await made.recorder.observe(Fixtures.window(["Export", "Cancel"]))
            return await made.recorder.report()
        }
        await emit("observe-permanent-lock", elapsed, report, made.memory)
        #expect(report.notes.count == 1, "the current sample is cut; with no sample nothing is ingested: \(report.notes)")
        #expect(Self.ms(elapsed) >= Self.budgetMS && Self.ms(elapsed) < Self.budgetMS * 2 + 500)
        #expect(await made.memory.status().diagnostics?.retainedWrites == 0)
        #expect(await made.memory.status().isReady, "a stop is not a degradation")
        await made.memory.close()
    }

    @Test("an action stopped under a lock that never goes: before, after and the brain all cut within the call's one budget")
    func actionUnderAPermanentLock() async throws {
        let made = try await composed(.act(target: "Platform", verb: .click, value: nil, section: nil), "measure-act")
        let record = action("measure-act")
        let (report, elapsed) = await stopped(made, releaseAfter: nil) {
            await made.recorder.record(record)
            return await made.recorder.report()
        }
        await emit("action-permanent-lock", elapsed, report, made.memory)
        #expect(report.notes.count == 3, "sample before, sample after, brain record: \(report.notes)")
        #expect(report.samples.isEmpty)
        #expect(Self.ms(elapsed) >= Self.budgetMS, "the budget is spent before anything is cut")
        #expect(Self.ms(elapsed) < Self.budgetMS * 2 + 200, "one shared budget, where one per fact would take three")
        #expect(await made.memory.status().diagnostics?.retainedWrites == 0)
        #expect(try await made.memory.sample(CaptureSampleKey(eventID: "measure-act", phase: .before)) == nil, "a cut fact is not on disk")
        await made.memory.close()
    }

    @Test("an action stopped under a lock released within the budget: every fact saved, once, nothing cut")
    func actionWithTheLockReleasedAfterTheStop() async throws {
        let made = try await composed(.act(target: "Platform", verb: .click, value: nil, section: nil), "measure-act-saved")
        let record = action("measure-act-saved")
        let release = Duration.milliseconds(Self.budgetMS / 2)
        let (report, elapsed) = await stopped(made, releaseAfter: release) {
            await made.recorder.record(record)
            return await made.recorder.report()
        }
        await emit("action-released-within-budget", elapsed, report, made.memory)
        #expect(report.notes.isEmpty, "\(report.notes)")
        #expect(report.samples == [.before, .after])
        #expect(await made.memory.status().diagnostics?.commits == 6, "the plan, two samples, two associations, the brain")
        #expect(try await made.memory.application(.record(eventID: "measure-act-saved")) != nil)
        await made.memory.close()
    }

    @Test("an action stopped and its memory closed by the owner right after: every remaining fact ends at once as closed")
    func actionWithTheMemoryClosedAfterTheStop() async throws {
        let made = try await composed(.act(target: "Platform", verb: .click, value: nil, section: nil), "measure-act-closed")
        let record = action("measure-act-closed")
        let (report, elapsed) = await stopped(made, releaseAfter: nil, closeAfterStop: true) {
            await made.recorder.record(record)
            return await made.recorder.report()
        }
        await emit("action-closed-after-stop", elapsed, report, made.memory)
        #expect(!report.notes.isEmpty && report.notes.allSatisfy { $0.contains("closed") }, "\(report.notes)")
        #expect(Self.ms(elapsed) < Self.budgetMS, "the close ends the waits; no budget runs out")
        #expect(await made.memory.status().state == .closed)
    }
}

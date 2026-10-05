//
//  MemoryServiceTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLiteMemory
import Synchronization
import Testing

@MainActor
@Suite("The memory service of a Knowledge directory", .serialized)
struct MemoryServiceTests {

    /// A store policy whose cycle is short, so a lock is held over many of them in a few milliseconds.
    private static let quick = MemoryService.Configuration(
        store: .init(lockBudget: .milliseconds(10), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(2)),
        reopenInterval: .seconds(60), finalizationBudget: .milliseconds(150)
    )

    /// Waits, a few milliseconds at a time and for at most two seconds, until `condition` holds.
    private static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("the first use creates the directory and memory.sqlite under it, and says the service is ready")
    func opensOnFirstUse() async throws {
        let directory = Fixtures.directory()
        let service = MemoryService(directory: directory)
        #expect(await service.status().state == .notOpened)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let status = await service.ready()
        #expect(status.isReady)
        #expect(status.path == directory.appendingPathComponent("memory.sqlite").path)
        #expect(status.diagnostics?.schemaVersion == 1)
        #expect(status.diagnostics?.bootstrappedNow == true)
        #expect(FileManager.default.fileExists(atPath: status.path))
        #expect(status.sentence.hasPrefix("memory: "))
        #expect(try await service.brain(of: Fixtures.bundle) == nil, "a new archive knows no application")
        await service.close()
    }

    @Test("ordinary contention at the open is waited out, cycle after cycle, never degraded (the supervision's case)")
    func openingUnderOrdinaryContention() async throws {
        let directory = Fixtures.directory()
        let first = MemoryService(directory: directory)
        try await first.open()
        await first.close()
        let writer = try ExternalWriter(directory.appendingPathComponent("memory.sqlite"))
        writer.lock()
        let service = MemoryService(directory: directory, configuration: Self.quick)
        let released = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            writer.release()
        }
        let began = ContinuousClock.now
        let status = await service.ready()
        try await released.value
        #expect(status.isReady, "a busy archive must be awaited, not degraded: \(status.state)")
        #expect(began.duration(to: .now) >= .milliseconds(90), "the open waited for the release, over several 10 ms cycles")
        await service.close()
    }

    @Test("a write under a lock held over several cycles waits, then commits once, with the store's own counts as the witness")
    func aWriteWaitsOutALockHeldOverSeveralCycles() async throws {
        let directory = Fixtures.directory()
        let service = MemoryService(directory: directory, configuration: Self.quick)
        try await service.open()
        let writer = try ExternalWriter(service.url)
        writer.lock()
        let event = Fixtures.context("held-1").event(app: nil, occurredAtMS: 1)
        let write = Task { try await service.record(event) }
        await Self.until { (await service.status().diagnostics?.retainedWrites ?? 0) == 1 }
        await Self.until { (await service.status().diagnostics?.exhaustedCycles ?? 0) >= 3 }
        #expect((await service.status().diagnostics?.exhaustedCycles ?? 0) >= 3, "several budgets ran out while the lock was held")
        #expect(try await service.event("held-1") == nil, "nothing was written while the lock was held")
        writer.release()
        #expect(try await write.value == .committed)
        #expect(try await service.event("held-1") != nil)
        #expect(await service.status().diagnostics?.commits == 1, "one commit for one fact, however many cycles it waited")
        #expect(await service.status().isReady)
        await service.close()
    }

    @Test("two callers wait for one open; cancelling one stops only its wait, the other opens when the lock goes")
    func twoCallersOneCancelled() async throws {
        let directory = Fixtures.directory()
        let first = MemoryService(directory: directory)
        try await first.open()
        await first.close()
        let writer = try ExternalWriter(directory.appendingPathComponent("memory.sqlite"))
        writer.lock()
        let service = MemoryService(directory: directory, configuration: Self.quick)
        let cancelled = Task { try await service.open() }
        let patient = Task { try await service.open() }
        await Self.until { await service.status().state == .opening }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        let outcome = await cancelled.result
        if case .failure(let error) = outcome { #expect(error is CancellationError, "\(error)") }
        else { Issue.record("the cancelled caller opened") }
        #expect(await service.status().state == .opening, "the owner's attempt goes on for the other caller")
        writer.release()
        try await patient.value
        #expect(await service.status().isReady)
        await service.close()
    }

    @Test("closing during the open attempt ends it: the waiting callers are told the memory is closed, and nothing is left open")
    func closeDuringTheOpenAttempt() async throws {
        let directory = Fixtures.directory()
        let first = MemoryService(directory: directory)
        try await first.open()
        await first.close()
        let writer = try ExternalWriter(directory.appendingPathComponent("memory.sqlite"))
        writer.lock()
        let service = MemoryService(directory: directory, configuration: Self.quick)
        let waiting = Task { try await service.open() }
        await Self.until { await service.status().state == .opening }
        await service.close()
        let outcome = await waiting.result
        if case .failure(let error) = outcome { #expect((error as? MemoryUnavailable)?.description == "the memory is closed") }
        else { Issue.record("a closed service opened") }
        #expect(await service.status().state == .closed)
        writer.release()
        let failure = await #expect(throws: MemoryUnavailable.self) { try await service.open() }
        #expect(failure?.description == "the memory is closed")
    }

    @Test("a directory that cannot be created leaves the service degraded: a state, a sentence, and operations that say so, nothing replayed")
    func degradesWithoutThrowingElsewhere() async throws {
        let service = MemoryService(directory: try Fixtures.blockedDirectory(),
                                    configuration: MemoryService.Configuration(reopenInterval: .seconds(60)))
        let status = await service.ready()
        guard case .degraded(let reason) = status.state else {
            Issue.record("expected a degraded service, got \(status.state)")
            return
        }
        #expect(reason.hasPrefix("could not open: "))
        #expect(status.sentence.contains("tools go on without it"))
        #expect(status.diagnostics == nil)
        let failure = await #expect(throws: MemoryUnavailable.self) { try await service.brain(of: Fixtures.bundle) }
        #expect(failure?.description == reason, "every operation answers the one reason, not a new attempt")
        let write = await #expect(throws: MemoryUnavailable.self) {
            _ = try await service.record(Fixtures.context().event(app: nil, occurredAtMS: 1))
        }
        #expect(write?.description == reason)
        await service.close()
        #expect(await service.status().state == .closed)
    }

    @Test("a degraded service tries again after its interval, and recovers once the directory can be made")
    func recoversAfterTheInterval() async throws {
        let blocked = try Fixtures.blockedDirectory()
        let service = MemoryService(directory: blocked,
                                    configuration: MemoryService.Configuration(reopenInterval: .milliseconds(10)))
        guard case .degraded = await service.ready().state else {
            Issue.record("expected a degraded service")
            return
        }
        // The cause is removed: the file in the directory's place goes, so the directory can be created.
        try FileManager.default.removeItem(at: blocked.deletingLastPathComponent())
        try await Task.sleep(for: .milliseconds(20))
        let recovered = await service.ready()
        #expect(recovered.isReady, "\(recovered.state)")
        #expect(try await service.brain(of: Fixtures.bundle) == nil)
        await service.close()
    }

    @Test("close is definitive: nothing is written afterwards and every operation says the memory is closed")
    func closeIsDefinitive() async throws {
        let service = MemoryService(directory: Fixtures.directory())
        #expect(await service.ready().isReady)
        await service.close()
        let failure = await #expect(throws: MemoryUnavailable.self) {
            _ = try await service.record(Fixtures.context().event(app: nil, occurredAtMS: 1))
        }
        #expect(failure?.description == "the memory is closed")
        #expect(await service.ready().state == .closed, "ready does not reopen a closed service")
        await service.close()
    }

    // MARK: Finalizations: the ordinary wait, and the budget that starts at the stop

    @Test("a finalization is not cut by its caller's cancellation; once the caller is cancelled, its budget bounds it")
    func finalizationsAreBoundedAndNotCut() async throws {
        let service = MemoryService(directory: Fixtures.directory(), configuration: Self.quick)
        try await service.open()
        // A caller cancelled before it finalizes, the archive free: the fact is still written.
        let event = Fixtures.context("final-1").event(app: nil, occurredAtMS: 1)
        let cancelledCaller = Task { () throws -> MemoryReceipt in
            await Self.until { Task.isCancelled }
            return try await service.finalize { try await service.record(event) }
        }
        cancelledCaller.cancel()
        #expect(try await cancelledCaller.value == .committed)
        #expect(try await service.event("final-1") != nil)
        // The archive held by another writer past the budget, the caller cancelled already: the budget
        // runs from the call, and the finalization ends as an explicit gap. (The budget never bounds an
        // uncancelled caller: that case is `ordinaryContentionIsWaitedOut`.)
        let writer = try ExternalWriter(service.url)
        writer.lock()
        let late = Fixtures.context("final-2").event(app: nil, occurredAtMS: 2)
        let alreadyCancelled = Task { () throws -> MemoryReceipt in
            await Self.until { Task.isCancelled }
            return try await service.finalize { try await service.record(late) }
        }
        alreadyCancelled.cancel()
        let began = ContinuousClock.now
        let outcome = await alreadyCancelled.result
        #expect(began.duration(to: .now) < .seconds(2), "bounded: the budget ran at once")
        if case .failure(let error) = outcome { #expect(MemoryService.isCancellation(error), "\(error)") }
        else { Issue.record("expected the budget to end the wait, got \(outcome)") }
        writer.release()
        #expect(try await service.event("final-2") == nil, "nothing was written: the gap is real, not a late commit")
        #expect(await service.status().isReady, "a spent budget degrades nothing")
        await service.close()
    }

    @Test("ordinary contention past the budget is waited out, with no stop: the same fact is saved once when the lock goes")
    func ordinaryContentionIsWaitedOut() async throws {
        let service = MemoryService(directory: Fixtures.directory(), configuration: Self.quick)
        try await service.open()
        let writer = try ExternalWriter(service.url)
        writer.lock()
        let event = Fixtures.context("ordinary-1").event(app: nil, occurredAtMS: 1)
        let caller = Task { try await service.finalize { try await service.record(event) } }
        await Self.until { (await service.status().diagnostics?.retainedWrites ?? 0) == 1 }
        // Three budgets (150 ms each) pass with the lock held and nobody stopping the caller.
        try await Task.sleep(for: .milliseconds(450))
        #expect(await service.status().diagnostics?.retainedWrites == 1, "the write is still offered, cycle after cycle")
        #expect(try await service.event("ordinary-1") == nil)
        writer.release()
        #expect(try await caller.value == .committed)
        #expect(try await service.event("ordinary-1") != nil, "the fact, saved once the other writer let go")
        #expect(await service.status().diagnostics?.commits == 1, "once: however many cycles it waited")
        #expect(await service.status().isReady)
        await service.close()
    }

    @Test("a stop during an ordinary wait starts the budget there: the finalization ends as a gap when the lock does not go, and the cleanup can proceed")
    func aStopDuringTheWaitStartsTheBudget() async throws {
        let service = MemoryService(directory: Fixtures.directory(), configuration: Self.quick)
        try await service.open()
        let writer = try ExternalWriter(service.url)
        writer.lock()
        let event = Fixtures.context("stopped-1").event(app: nil, occurredAtMS: 1)
        let caller = Task { try await service.finalize { try await service.record(event) } }
        await Self.until { (await service.status().diagnostics?.retainedWrites ?? 0) == 1 }
        // Well past one budget, the wait is still ordinary.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await service.status().diagnostics?.retainedWrites == 1)
        let stop = ContinuousClock.now
        caller.cancel()
        let outcome = await caller.result
        let afterStop = stop.duration(to: .now)
        #expect(afterStop >= .milliseconds(150), "the budget ran from the stop, not from the start of the wait")
        #expect(afterStop < .seconds(2), "and it bounded the finalization")
        if case .failure(let error) = outcome { #expect(MemoryService.isCancellation(error), "\(error)") }
        else { Issue.record("expected a gap, got \(outcome)") }
        #expect(await service.status().diagnostics?.retainedWrites == 0, "the write was let go of: nothing is left waiting")
        writer.release()
        #expect(try await service.event("stopped-1") == nil, "the gap is real and due to the stop")
        #expect(await service.status().isReady)
        await service.close()
    }

    @Test("a lock released within the budget after the stop: the known fact is saved, once, with nothing replayed")
    func aReleaseWithinTheBudgetAfterTheStopSaves() async throws {
        let service = MemoryService(directory: Fixtures.directory(), configuration: Self.quick)
        try await service.open()
        let writer = try ExternalWriter(service.url)
        writer.lock()
        let event = Fixtures.context("saved-after-stop").event(app: nil, occurredAtMS: 1)
        let caller = Task { try await service.finalize { try await service.record(event) } }
        await Self.until { (await service.status().diagnostics?.retainedWrites ?? 0) == 1 }
        caller.cancel()
        writer.release()
        #expect(try await caller.value == .committed)
        #expect(try await service.event("saved-after-stop") != nil)
        #expect(await service.status().diagnostics?.commits == 1)
        await service.close()
    }

    @Test("the stop of one caller abandons no other: the second finalization keeps waiting and is saved when the lock goes")
    func theSecondCallerIsNotAbandonedByTheFirstsStop() async throws {
        let service = MemoryService(directory: Fixtures.directory(), configuration: Self.quick)
        try await service.open()
        let writer = try ExternalWriter(service.url)
        writer.lock()
        let first  = Fixtures.context("two-first").event(app: nil, occurredAtMS: 1)
        let second = Fixtures.context("two-second").event(app: nil, occurredAtMS: 2)
        let stopped = Task { try await service.finalize { try await service.record(first) } }
        let patient = Task { try await service.finalize { try await service.record(second) } }
        await Self.until { (await service.status().diagnostics?.retainedWrites ?? 0) == 2 }
        stopped.cancel()
        let outcome = await stopped.result
        if case .failure(let error) = outcome { #expect(MemoryService.isCancellation(error), "\(error)") }
        else { Issue.record("expected the stopped caller's gap, got \(outcome)") }
        #expect(await service.status().diagnostics?.retainedWrites == 1, "the other caller's write is still offered")
        writer.release()
        #expect(try await patient.value == .committed)
        #expect(try await service.event("two-second") != nil)
        #expect(try await service.event("two-first") == nil, "the stopped caller's fact is the gap")
        #expect(await service.status().diagnostics?.commits == 1)
        #expect(await service.status().isReady)
        await service.close()
    }

    @Test("two services on one directory share one archive: what one writes the other reads")
    func twoServicesShareTheFile() async throws {
        let directory = Fixtures.directory()
        let writer = MemoryService(directory: directory)
        let reader = MemoryService(directory: directory)
        let context = Fixtures.context("shared-1")
        try await Fixtures.plan(.status, ActionContext(eventID: "shared-1", source: .cli, streamID: "mecum-cli-1"), in: writer)
        let read = try await reader.call("shared-1")
        #expect(read?.request.tool == .status)
        #expect(read?.event.source == .cli)
        #expect(read?.progress.status == .planned)
        #expect(try await reader.calls(inTrace: context.traceID ?? "", after: nil, limit: 5).isEmpty,
                "the second service wrote under its own trace")
        await writer.close()
        await reader.close()
    }

    @Test("the three times are kept apart: the calendar as the facts' source says it, the Brain's clock never backwards, durations monotone")
    func theThreeTimesAreKeptApart() {
        let walls = Mutex([1_700_000_000.900, 1_700_000_000.400, 1_700_000_001.000, 1_700_000_000.100])
        let ticks = Mutex<Int64>(5_000_000_000)
        let clock = MemoryClock(
            wall     : { Date(timeIntervalSince1970: walls.withLock { $0.isEmpty ? 1_700_000_001.000 : $0.removeFirst() }) },
            monotonic: { ticks.withLock { $0 += 3_000_000; return $0 } }
        )
        // The reference was read at creation: calendar 900, monotonic 5 003 ms; every monotonic read adds 3 ms.
        let first = clock.calendarMS(), second = clock.calendarMS(), third = clock.calendarMS()
        #expect([first, second, third] == [1_700_000_000_400, 1_700_000_001_000, 1_700_000_000_100],
                "the calendar of the facts is kept as it was, backwards included")
        let brainOne = clock.brainMS(), brainTwo = clock.brainMS()
        #expect(brainOne == 1_700_000_000_903 && brainTwo == 1_700_000_000_906,
                "the Brain's clock is the reference plus the monotonic time elapsed, whatever the wall did meanwhile")
        let start = clock.monotonicNS(), end = clock.monotonicNS()
        #expect(MemoryClock.durationMS(from: start, to: end) == 3)
        #expect(MemoryClock.durationMS(from: end, to: start) == 0, "never below zero")
    }

    // MARK: The supervision's probes, carried into the repository

    @Test("S3-d supervision: compound observed effects keep their distinct values through the service")
    func supervisionEffectsRemainDistinct() async throws {
        let service = MemoryService(directory: Fixtures.directory())
        let one = SceneEffect.menuOpened(labels: ["A|B", "C"])
        let two = SceneEffect.menuOpened(labels: ["A", "B|C"])
        #expect(one != two)
        for (id, effect) in [("effect-one", one), ("effect-two", two)] {
            try await Fixtures.plan(.act(target: "Menu", verb: .click, value: nil, section: nil), Fixtures.context(id), in: service)
            let stamp = service.clock.calendarMS()
            _ = try await service.advance([AgentCallTransition(id, .started(atMS: stamp))])
            _ = try await service.advance([AgentCallTransition(id, .init(.completed,
                result: .outcome(.foundActed, message: "menu observed"), endedAtMS: stamp, durationMS: 0,
                observedEffect: ObservedEffect(effect)))])
        }
        let left = try #require(try await service.call("effect-one")?.progress.observedEffect)
        let right = try #require(try await service.call("effect-two")?.progress.observedEffect)
        #expect(!left.isExactly(right), "different compound effects must remain distinguishable")
        #expect(left.sceneEffect == one && right.sceneEffect == two)
        #expect(left.labels == ["A|B", "C"] && right.labels == ["A", "B|C"])
        await service.close()
    }

    @Test("S3-d supervision: fact time preserves the source's calendar, separate from the Brain clock")
    func supervisionSourceCalendarIsNotClamped() {
        let walls = Mutex([1_700_000_000.900, 1_700_000_000.400])
        let clock = MemoryClock(wall: { Date(timeIntervalSince1970: walls.withLock { $0.isEmpty ? 1_700_000_000.400 : $0.removeFirst() }) })
        let first = Fixtures.context("fact-first").event(app: nil, occurredAtMS: clock.calendarMS())
        let second = Fixtures.context("fact-second").event(app: nil, occurredAtMS: clock.calendarMS())
        // The first calendar read was the reference, taken when the clock was made.
        #expect(first.occurredAtMS == 1_700_000_000_400)
        #expect(second.occurredAtMS == 1_700_000_000_400, "source time must remain the original fact time")
        #expect(clock.brainMS() >= 1_700_000_000_900, "the Brain's clock keeps the reference, never the clamped calendar")
    }

    @Test("S3-d supervision: open_session's own observation retains its exact creating call")
    func supervisionOpenObservationRetainsTheCall() {
        let call = Fixtures.context("opening-call", session: nil)
        let observation = call.another(eventID: "opening-observation", sessionID: "opened-session")
        #expect(observation.originEventID == call.eventID,
                "same stream and trace alone cannot attribute a sample to its creating open_session")
        #expect(observation.parentEventID == nil, "the relation is the origin, not a batch's parent")
        let event = observation.event(app: Fixtures.app, occurredAtMS: 1)
        #expect(event.originEventID == "opening-call" && event.kind == .action, "the kind is the caller's: the recorder records it as an observation")
    }

    @Test("a reason never carries what the agent typed or read: the store's own words, or a type name")
    func reasonsAreSafe() {
        struct Secret: Error { let label = "Export now" }
        #expect(MemoryService.describe(Secret()) == "Secret")
        #expect(MemoryService.describe(CancellationError()) == "cancelled")
        #expect(MemoryService.describe(MemoryUnavailable("closed")) == "closed")
        #expect(MemoryService.describe(AgentCallError.missingCall(eventID: "e1")).contains("missingCall"))
        #expect(MemoryService.isCancellation(CancellationError()) && MemoryService.isCancellation(MemoryStoreError.cancelled(.begin)))
        #expect(!MemoryService.isCancellation(MemoryUnavailable("x")))
    }
}

/// The read-only role and the Brain catalogue over it: three answers apart, a reload that sees new
/// writes, nothing created by a reading.
@MainActor
@Suite("Reading the living memory: the Brain catalogue", .serialized)
struct BrainCatalogTests {

    @Test("no archive is missing and stays missing; a valid empty archive is loaded and empty; an unreadable one is unavailable")
    func threeAnswers() async throws {
        // A directory with an older JSON knowledge file and no archive: the JSON is not read, the archive is missing.
        let legacy = Fixtures.directory()
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(#"{"bundleID":"com.apple.calculator","brain":{}}"#.utf8).write(to: legacy.appendingPathComponent("com.apple.calculator.json"))
        let missing = MemoryService(directory: legacy)
        #expect(await BrainCatalog.load(from: missing) == .missing(path: missing.url.path))
        #expect(!missing.archiveExists, "the reading created nothing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: legacy.path) == ["com.apple.calculator.json"], "the JSON left as it was")
        let empty = MemoryService(directory: Fixtures.directory())
        try await empty.open()
        #expect(await BrainCatalog.load(from: empty) == .loaded([]))
        await empty.close()
        let broken = Fixtures.directory()
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data(String(repeating: "not a database ", count: 300).utf8).write(to: broken.appendingPathComponent("memory.sqlite"))
        let unreadable = MemoryService(directory: broken)
        guard case .unavailable(let reason) = await BrainCatalog.load(from: unreadable) else {
            Issue.record("an unreadable archive was not said unavailable")
            return
        }
        #expect(reason.contains("file is not a database"), "the store's own refusal: the reader does not degrade the service")
        #expect(await unreadable.status().state == .notOpened)
        await unreadable.close()
    }

    @Test("an observed application is listed with its Brain and counts; a reload after another writer's write sees it")
    func listedAndReloaded() async throws {
        let directory = Fixtures.directory()
        let reader = MemoryService(directory: directory)
        try await reader.open()
        #expect(await BrainCatalog.load(from: reader) == .loaded([]))
        // Another service on the same file writes an observation, as a worker's session does.
        let writer = MemoryService(directory: directory)
        let clock = writer.clock
        let brain = BrainMemory(brains: writer, applications: writer, clock: { clock.brainNow() })
        let context = Fixtures.context("catalogue-1")
        try await Fixtures.plan(.observe, context, in: writer)
        let recorder = CallRecorder(memory: writer, brain: brain, context: context, sessionRevision: 1, requestedAt: clock.brainNow())
        _ = await recorder.observe(Fixtures.window(["Export", "Cancel", "Platform"]))
        await writer.close()
        guard case .loaded(let entries) = await BrainCatalog.load(from: reader) else {
            Issue.record("expected a loaded catalogue")
            return
        }
        #expect(entries.map(\.bundleID) == [Fixtures.bundle])
        #expect(entries.first?.brain.objects.count == 3)
        #expect(entries.first?.summary.events == 1 && entries.first?.summary.samples == 1)
        #expect(entries.first?.lastLearned != nil)
        #expect(await reader.status().technicalDetails.contains { $0.hasPrefix("schema 1, SQLite ") })
        await reader.close()
    }

    @Test("observations a session records on its own, with no call, reach the catalogue: the app's snapshot fixture's path")
    func ownObservationsReachTheCatalogue() async throws {
        let directory = Fixtures.directory()
        let memory = MemoryService(directory: directory)
        let clock = memory.clock
        let brain = BrainMemory(brains: memory, applications: memory, clock: { clock.brainNow() })
        for (index, labels) in [["Bold", "Italic", "Save"], ["Bold", "Italic", "Save", "Format"]].enumerated() {
            let context = ActionContext(eventID: "fixture-observation-\(index)", source: .app, streamID: "snapshot",
                                        traceID: "snapshot-trace", sessionID: "snapshot-session")
            let recorder = CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: Int64(index + 1),
                                        requestedAt: clock.brainNow())
            _ = await recorder.observe(Fixtures.window(labels), recordingObservationOf: Fixtures.app)
            let notes = await recorder.report().notes
            #expect(notes.isEmpty, "\(notes)")
        }
        await memory.close()
        let reader = MemoryService(directory: directory)
        guard case .loaded(let entries) = await BrainCatalog.load(from: reader) else {
            Issue.record("expected a loaded catalogue")
            return
        }
        #expect(entries.map(\.bundleID) == [Fixtures.bundle])
        #expect(entries.first?.brain.objects.count == 4)
        #expect(entries.first?.summary.events == 2 && entries.first?.summary.samples == 2)
        await reader.close()
    }
}

//
//  CallRecorderTests.swift
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
import Testing

@MainActor
@Suite("The recorder of one call")
struct CallRecorderTests {

    /// The Brain's clock a call is asked for at, fixed, as the runtime reads it once per recorder.
    private static let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// A service, the brain seam over it and a recorder for `context`, the call planned as the tools plan it.
    private func composed(_ request: AgentCallRequest = .observe, context: ActionContext = Fixtures.context(),
                          directory: URL = Fixtures.directory(), planned: Bool = true)
        async throws -> (memory: MemoryService, brain: BrainMemory, recorder: CallRecorder) {
        let memory = MemoryService(directory: directory)
        let clock  = memory.clock
        let brain  = BrainMemory(brains: memory, applications: memory, clock: { clock.brainNow() })
        if planned { try await Fixtures.plan(request, context, in: memory) }
        return (memory, brain, CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: 3,
                                            requestedAt: Self.requestedAt))
    }

    @Test("an observation writes the current sample with its quality, ingests the scene once under it, and answers the enriched scene")
    func observationIsRecordedOnce() async throws {
        let context = Fixtures.context("obs-1")
        let (memory, brain, recorder) = try await composed(.observe, context: context)
        let window = Fixtures.window(["Export", "Cancel", "Platform"])
        let scene  = await recorder.observe(window)
        #expect(scene.elements.count == 3)
        let report = await recorder.report()
        #expect(report.eventID == "obs-1")
        #expect(report.samples == [.current])
        #expect(report.learned == .observed(created: 3, updated: 0, skippedAmbiguous: 0))
        #expect(report.sessionRevision == 3)
        #expect(report.notes.isEmpty)
        let key = CaptureSampleKey(eventID: "obs-1", phase: .current)
        let sample = try #require(try await memory.sample(key))
        #expect(sample.quality.completeness == .complete)
        #expect(sample.sessionRevision == 3)
        #expect(sample.surface == .window)
        #expect(sample.elements.map(\.label) == ["Export", "Cancel", "Platform"])
        #expect(try await memory.associations(of: key).count == 1, "a complete sample is associated with a structural scene")
        #expect(try await memory.application(.observe(key))?.outcome == .observed(created: 3, updated: 0, skippedAmbiguous: 0))
        #expect(try await memory.brain(of: Fixtures.bundle)?.objects.count == 3)
        // The same facts offered again at the same instant (a retransmission) move nothing: one sample, one application.
        let again = CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: 3, requestedAt: Self.requestedAt)
        _ = await again.observe(window)
        #expect(await again.report().notes.isEmpty)
        #expect(try await memory.brain(of: Fixtures.bundle)?.ingestEpoch == 1)
        #expect(try await memory.application(.observe(key))?.command.requestedAtMS == 1_700_000_000_000)
        // Offered at another instant it is another command under the one key: a conflict the store refuses, noted.
        let later = CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: 3,
                                 requestedAt: Self.requestedAt.addingTimeInterval(1))
        _ = await later.observe(window)
        #expect(await later.report().notes.contains { $0.hasPrefix("brain observe: identity(") })
        #expect(try await memory.brain(of: Fixtures.bundle)?.ingestEpoch == 1, "no new counter")
        await memory.close()
    }

    @Test("a session's own observation after open_session is an observation event whose origin is the call, with its sample and ingest under it")
    func theOwnObservationKeepsItsOrigin() async throws {
        let call = Fixtures.context("open-1", session: nil)
        let (memory, brain, _) = try await composed(.openSession(app: "Test", window: nil), context: call)
        let own = call.another(eventID: "open-1.observation", sessionID: "S-1")
        #expect(own.originEventID == "open-1" && own.sessionID == "S-1" && own.traceID == call.traceID)
        let recorder = CallRecorder(memory: memory, brain: brain, context: own, sessionRevision: 1, requestedAt: Self.requestedAt)
        let scene = await recorder.observe(Fixtures.window(["Export", "Cancel"]), recordingObservationOf: Fixtures.app)
        #expect(scene.elements.count == 2)
        let report = await recorder.report()
        #expect(report.eventID == "open-1.observation" && report.samples == [.current] && report.notes.isEmpty, "\(report.notes)")
        let event = try #require(try await memory.event("open-1.observation"))
        #expect(event.kind == .observation && event.originEventID == "open-1" && event.app == Fixtures.app && event.sessionID == "S-1")
        #expect(event.parentEventID == nil, "an observation is no batch step")
        #expect(try await memory.sample(CaptureSampleKey(eventID: "open-1.observation", phase: .current)) != nil)
        #expect(try await memory.application(.observe(CaptureSampleKey(eventID: "open-1.observation", phase: .current))) != nil)
        #expect(try await memory.call("open-1")?.progress.status == .planned, "the call's own event is untouched")
        await memory.close()
    }

    @Test("an action's record writes its before and after samples and teaches the brain only from an effect on an element")
    func actionIsRecorded() async throws {
        let context = Fixtures.context("act-1")
        let (memory, _, recorder) = try await composed(.act(target: "Platform", verb: .click, value: nil, section: nil),
                                                       context: context)
        let before = Fixtures.window(["Export", "Platform"])
        let after  = Fixtures.window(["Export", "Platform", "Desktop", "Mobile"], surface: .popupUnion)
        let effect = SceneEffect.menuOpened(labels: ["Desktop", "Mobile"])
        await recorder.record(ActionRecord(
            bundleID: Fixtures.bundle, element: before.scene.elements[1], verb: .click, effect: effect,
            windowTitleAfter: after.scene.windowTitle, before: before, after: after, attempt: .delivered
        ))
        let report = await recorder.report()
        #expect(report.effect == effect)
        #expect(report.samples == [.before, .after])
        #expect(report.notes.isEmpty)
        if case .recorded(_, _, let evidence)? = report.learned { #expect(evidence == 1) }
        else { Issue.record("the menu reveal was not recorded: \(String(describing: report.learned))") }
        #expect(try await memory.sample(CaptureSampleKey(eventID: "act-1", phase: .before))?.elements.count == 2)
        #expect(try await memory.sample(CaptureSampleKey(eventID: "act-1", phase: .after))?.surface == .popupUnion)
        #expect(try await memory.application(.record(eventID: "act-1")) != nil)
        #expect(try await memory.brain(of: Fixtures.bundle)?.transitions.count == 1)
        await memory.close()
    }

    @Test("a miss keeps what was perceived and teaches nothing: no element, no application")
    func missIsRecordedWithoutLearning() async throws {
        let context = Fixtures.context("miss-1")
        let (memory, _, recorder) = try await composed(.act(target: "Nowhere", verb: .click, value: nil, section: nil),
                                                       context: context)
        await recorder.record(ActionRecord(
            bundleID: Fixtures.bundle, element: nil, verb: .click, effect: nil, windowTitleAfter: nil,
            before: Fixtures.window(["Export"]), after: nil, attempt: .notAttempted(reason: "honest_miss")
        ))
        let report = await recorder.report()
        #expect(report.samples == [.before] && report.effect == nil && report.learned == nil && report.notes.isEmpty)
        #expect(try await memory.application(.record(eventID: "miss-1")) == nil)
        #expect(try await memory.brain(of: Fixtures.bundle)?.objects.isEmpty ?? true, "the sample named the app; the brain learned nothing")
        await memory.close()
    }

    @Test("an input's record writes before, menu and after, and the brain learns nothing from it")
    func inputIsRecorded() async throws {
        let context = Fixtures.context("in-1")
        let (memory, _, recorder) = try await composed(.contextMenu(target: "Export", item: "Copy", section: nil),
                                                       context: context)
        let before = Fixtures.window(["Export"])
        let menu   = Fixtures.window(["Copy", "Paste"], title: "Menu", surface: .popupUnion)
        let after  = Fixtures.window(["Export"])
        await recorder.record(InputRecord(
            bundleID: Fixtures.bundle, input: .contextMenu(on: "Export", item: "Copy"), target: before.scene.elements[0],
            before: before, menu: menu, after: after, effect: .elementsDisappeared(labels: ["Copy"]), attempt: .delivered
        ))
        let report = await recorder.report()
        #expect(report.samples == [.before, .menu, .after])
        #expect(report.effect == .elementsDisappeared(labels: ["Copy"]))
        #expect(report.learned == nil)
        #expect(try await memory.sample(CaptureSampleKey(eventID: "in-1", phase: .menu))?.elements.map(\.label) == ["Copy", "Paste"])
        #expect(try await memory.associations(of: CaptureSampleKey(eventID: "in-1", phase: .menu)).isEmpty,
                "a menu is kept but never associated with a scene")
        #expect(try await memory.brain(of: Fixtures.bundle)?.transitions.isEmpty ?? true)
        #expect(try await memory.application(.record(eventID: "in-1")) == nil)
        await memory.close()
    }

    @Test("a degraded memory is notes in the report, never a failure of the call, and the notes name no label")
    func degradedMemoryIsANote() async throws {
        let (memory, _, recorder) = try await composed(.observe, context: Fixtures.context("deg-1"),
                                                       directory: try Fixtures.blockedDirectory(), planned: false)
        let window = Fixtures.window(["Export now"])
        let scene  = await recorder.observe(window)
        #expect(scene == window.scene, "no brain to enrich from: the scene as perceived")
        let report = await recorder.report()
        #expect(report.samples.isEmpty && report.learned == nil)
        #expect(report.notes.count == 1)
        #expect(report.notes[0].hasPrefix("sample current: could not open: "))
        #expect(!report.notes.joined().contains("Export"))
        await memory.close()
    }

    @Test("a sample for a call the memory does not hold is a note, and the brain is not asked")
    func unplannedCallIsANote() async throws {
        let (memory, _, recorder) = try await composed(.observe, context: Fixtures.context("never-planned"), planned: false)
        _ = await recorder.observe(Fixtures.window(["Export"]))
        let report = await recorder.report()
        #expect(report.samples.isEmpty && report.learned == nil)
        #expect(report.notes.count == 1 && report.notes[0].hasPrefix("sample current: "))
        #expect(try await memory.brain(of: Fixtures.bundle) == nil)
        await memory.close()
    }

    // MARK: The supervision's probe, carried into the repository

    @Test("S3-d supervision: an uncancelled observation outlives the finalization budget under ordinary contention and still records its sample")
    func supervisionNormalObservationIsNotShutdown() async throws {
        let service = MemoryService(directory: Fixtures.directory(), configuration: .init(
            store: .init(lockBudget: .milliseconds(10), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(2)),
            finalizationBudget: .milliseconds(20)
        ))
        let context = Fixtures.context("ordinary-observation")
        try await Fixtures.plan(.observe, context, in: service)
        let clock = service.clock
        let brain = BrainMemory(brains: service, applications: service, clock: { clock.brainNow() })
        let recorder = CallRecorder(memory: service, brain: brain, context: context, sessionRevision: 1, requestedAt: clock.brainNow())
        // Another writer holds the archive for 250 ms, well past the 20 ms budget; nobody stops the caller.
        let writer = try ExternalWriter(service.url)
        writer.lock()
        let release = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(250))
            writer.release()
        }
        #expect(!Task.isCancelled)
        _ = await recorder.observe(Fixtures.window(["Export", "Cancel", "Platform"]))
        try await release.value
        let report = await recorder.report()
        #expect(report.notes.isEmpty, "ordinary contention must be waited out, never a gap at a deadline: \(report.notes)")
        let key = CaptureSampleKey(eventID: context.eventID, phase: .current)
        #expect(try await service.sample(key) != nil, "the current sample exists once the other writer released its lock")
        #expect(try await service.application(.observe(key)) != nil, "the brain's ingest received the observation")
        #expect(await service.status().diagnostics?.commits == 4, "one commit per fact: the plan, the sample, its association, the ingest")
        #expect(await service.status().isReady)
        await service.close()
    }

    @Test("a context makes the event the call is recorded as, and a child names its batch and position")
    func contextMakesEvents() {
        let batch = ActionContext(eventID: "b", source: .cli, streamID: "mecum-cli-7", traceID: "t", sessionID: "s")
        let step  = batch.child(2, eventID: "b.2")
        #expect(step.parentEventID == "b" && step.parentPosition == 2 && step.sessionID == "s" && step.traceID == "t")
        let event = step.event(app: Fixtures.app, occurredAtMS: 1_700_000_000_000, monotonicNS: 42)
        #expect(event.eventID == "b.2" && event.kind == .action && event.source == .cli && event.streamID == "mecum-cli-7")
        #expect(event.app == Fixtures.app && event.occurredAtMS == 1_700_000_000_000 && event.monotonicNS == 42)
        #expect(event.captureStatus == .unknown)
    }
}

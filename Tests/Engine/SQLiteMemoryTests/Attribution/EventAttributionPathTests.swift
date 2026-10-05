//
//  EventAttributionPathTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The path from an observed input to its attribution, by explicit assignment only: a Watcher input
/// without a task, its captures when they exist, an episode and a candidate label given later, a
/// correlation with an agent call already recorded, and verifications of every verdict. Read back
/// after reopening, the facts are as they were and the brain has not moved.
@Suite("Observed input to explicit attribution, end to end", .serialized)
struct EventAttributionPathTests {

    private typealias F = AttributionFixtures

    @Test("input, captures, later episode and label, correlation and verifications survive reopening; samples and their quality stay, an unknown verdict stays unknown, and the brain does not move")
    func path() async throws {
        let memory = try await F.open()
        // The agent's call, recorded and concluded first.
        _ = try await memory.calls.record(try F.agentCall("a1"))
        _ = try await memory.calls.advance([AgentCallTransition("a1", .started),
                                            AgentCallTransition("a1", AgentCallProgress(.completed, result: .outcome(.foundActed, message: "Clicked Send."),
                                                                                        endedAtMS: F.t0 + 300))])
        // The Watcher's inputs, without any task: a click with captures before and after, a gap, a
        // hover whose after capture is partial and has no before, a focus of an unknown application.
        let inputs: [(MemoryEventRecord, ObservedInput)] = [
            (F.watcherEvent("w-click", at: F.t0 + 40, key: "seq-1", monotonicNS: 5_000), try F.click("Posta – Zoë")),
            (F.watcherEvent("w-gap", at: F.t0 + 41, key: "seq-gap"), try ObservedInput(kind: .gap, gap: .init(first: 2, last: 9), lostCritical: 1, lostCoalescible: 6)),
            (F.watcherEvent("w-hover", at: F.t0 + 42, stream: "watcher-2"), try ObservedInput(kind: .hover, point: ScreenPoint(x: 3, y: 4), afterStatus: .partial)),
            (F.watcherEvent("w-focus", at: F.t0 + 43, app: nil), try ObservedInput(kind: .focus, targetPID: 412)),
        ]
        for (event, input) in inputs { #expect(try await memory.inputs.record(try ObservedInputRecord(event: event, input: input)) == .committed) }
        let samples = [
            CaptureSample(key: CaptureSampleKey(eventID: "w-click", phase: .before), windowTitle: "Posta – Zoë", sessionRevision: 3, surface: .window,
                          quality: CaptureQuality(walkCompleted: true, stoppedBy: nil, windowFound: true, isGrantAvailable: true, windowRole: "AXWindow",
                                                  windowSubrole: "AXStandardWindow", nodesVisited: 10, elementsEmitted: 0), elements: []),
            CaptureSample(key: CaptureSampleKey(eventID: "w-click", phase: .after), windowTitle: "Posta – Zoë", sessionRevision: 4, surface: .window,
                          quality: .unknown, elements: []),
            CaptureSample(key: CaptureSampleKey(eventID: "w-hover", phase: .after), windowTitle: nil, sessionRevision: nil, surface: .unknown,
                          quality: .unknown, elements: []),
        ]
        for sample in samples { #expect(try await memory.captures.record(sample) == .committed) }
        let summaries = try await memory.store.read { try $0.query("SELECT event_id, capture_status FROM memory_events ORDER BY event_id", []) {
            "\(try $0.text(0) ?? "") \(try $0.text(1) ?? "")" } }
        let brain = try await memory.brainRows()

        // Later, explicit attributions: the correlation, an episode with a candidate label, verifications.
        #expect(try await memory.inputs.record(try ActionCorrelation(watcherEventID: "w-click", agentEventID: "a1", basis: .assigned, timeOffsetMS: 40,
                                                                     explanation: "assigned by the fixture")) == .committed)
        for (id, verdict) in [("v-unknown", VerificationVerdict.unknown), ("v-passed", .passed), ("v-failed", .failed)] {
            _ = try await memory.verifications.record(try VerificationRecord(event: F.verificationEvent(id, at: F.t0 + 400), scope: .call, method: .sceneText,
                                                                            verdict: verdict, expectedText: "Inviato", observedText: verdict == .passed ? "Inviato" : nil))
        }
        let attribution = try TaskAttribution(
            occurrence: try TaskOccurrenceRecord(taskOccurrenceID: "t1", traceID: nil, startedAtMS: F.t0 + 40, status: .observed),
            memberships: [try TaskMembership(taskOccurrenceID: "t1", eventID: "w-click", position: 0, role: .observation),
                          try TaskMembership(taskOccurrenceID: "t1", eventID: "a1", position: 1, role: .action),
                          try TaskMembership(taskOccurrenceID: "t1", eventID: "v-unknown", position: 2, role: .verification)],
            labels: [try TaskLabelRecord(labelID: "l1", taskOccurrenceID: "t1", label: "Rispondere a Zoë", assignedBy: "fixture", status: .candidate,
                                         assignedAtMS: F.t0 + 5_000)])
        #expect(try await memory.tasks.attribute(attribution) == .committed)
        #expect(try await memory.brainRows() == brain, "an attribution moves no count, evidence or application")
        await memory.store.close()

        let reopened = try await F.open(at: memory.url)
        for (event, input) in inputs {
            let back = try #require(try await reopened.inputs.input(event.eventID))
            #expect(back.input.isExactly(input) && back.event.hasSameImmutableContent(as: event), Comment(rawValue: event.eventID))
        }
        for sample in samples { #expect(try await reopened.captures.sample(sample.key) == sample, "samples and their quality are as recorded") }
        #expect(try await reopened.captures.sample(CaptureSampleKey(eventID: "w-hover", phase: .before)) == nil, "no before is made up from a later capture")
        let summariesBack = try await reopened.store.read { try $0.query("SELECT event_id, capture_status FROM memory_events ORDER BY event_id", []) {
            "\(try $0.text(0) ?? "") \(try $0.text(1) ?? "")" } }
        #expect(summariesBack.filter { !$0.hasPrefix("v-") } == summaries, "the events' summaries are the ones their samples made")
        #expect(try await reopened.inputs.correlations(ofAgentEvent: "a1").map(\.watcherEventID) == ["w-click"])
        #expect(try await reopened.verifications.verification("v-unknown")?.record.verdict == .unknown,
                "a completed call, a correlation and a label do not make an unknown verification passed")
        let episode = try #require(try await reopened.tasks.occurrence("t1"))
        #expect(episode.endedAtMS == nil && episode.status == .observed, "an end not given stays absent")
        #expect(try await reopened.tasks.memberships(of: "t1").map(\.role) == [.observation, .action, .verification])
        #expect(try await reopened.tasks.labels(of: "t1").map(\.status) == [.candidate])
        #expect(try await reopened.calls.call("a1")?.progress.status == .completed)
        #expect(try await reopened.brainRows() == [0, 0, 0, 0])
        await reopened.store.close()
    }
}

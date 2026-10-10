//
//  OperationFactRepositoryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// OperationFactRepositoryTests prove the essential writes of a call on a real archive: the opening
/// before the effect with its task attribution, the conclusion after it with samples, effect and
/// typed verification in one transaction, retries that add nothing, conflicts that write nothing,
/// and the declared gaps of withheld values.
@Suite("The essential facts of a call: opening, conclusion, verification and declared gaps")
struct OperationFactRepositoryTests {

    static let app = AgentCallFixtures.app

    static func event(_ id: String, kind: MemoryEventKind = .action) -> MemoryEventRecord {
        MemoryEventRecord(
            eventID: id,
            source: .app,
            streamID: "worker-1",
            traceID: "message-1",
            sessionID: AgentCallFixtures.session,
            kind: kind,
            app: app,
            occurredAtMS: TaskFixtures.t0
        )
    }

    static func click(_ id: String) throws -> AgentCallRecord {
        try AgentCallRecord(event: event(id), request: .act(target: "Export", verb: .click, value: nil, section: nil))
    }

    static func sample(_ id: String, _ phase: CapturePhase, labels: [String] = ["Export", "Cancel"]) -> CaptureSample {
        SceneFixtures.sample(id, phase: phase, of: SceneFixtures.pixelsOnly(labels))
    }

    static func verification(
        _ call: String,
        _ check: OperationCheck,
        samples: [CaptureSampleKey]
    ) throws -> OperationVerification {
        let id = OperationVerification.eventID(call: call, condition: check.condition)
        return try OperationVerification(
            event: event(id, kind: .verification),
            callEventID: call,
            check: check,
            samples: samples
        )
    }

    static func conclusion(_ call: String, verdict: OperationCheck.Verdict = .passed) throws -> OperationConclusion {
        let check = OperationCheck(
            condition: .structuralEffect,
            method: .sceneDifference,
            verdict: verdict,
            expected: "menuOpened",
            observed: "menuOpened",
            limits: [.windowWide],
            performed: .requested,
            target: OperationCheck.Target(elementID: "control|export", role: "AXButton", label: "Export", section: nil)
        )
        let before = sample(call, .before), after = sample(call, .after, labels: ["PNG", "JPEG", "TIFF"])
        return try OperationConclusion(
            end: AgentCallTransition(
                call,
                AgentCallProgress(
                    .completed,
                    result: .outcome(.foundActed, message: "clicked 'Export'"),
                    endedAtMS: TaskFixtures.t0 + 30,
                    durationMS: 30
                )
            ),
            samples: [before, after],
            effect: try OperationEffect(callEventID: call, performed: .requested, target: check.target, checked: true),
            verifications: [try verification(call, check, samples: [before.key, after.key])]
        )
    }

    @Test("a call opened with its task attribution and concluded with samples, effect and verification reads back whole; offered again, nothing moves")
    func openAndConclude() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let attribution = try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        let opening = try OperationOpening(
            call: try Self.click("c1"),
            startedAtMS: TaskFixtures.t0 + 1,
            attribution: attribution
        )
        #expect(try await memory.facts.open(opening) == .committed)
        #expect(try await memory.facts.open(opening) == .alreadyApplied)
        #expect(try await memory.calls.call("c1")?.progress.status == .started)
        let conclusion = try Self.conclusion("c1")
        #expect(try await memory.facts.conclude(conclusion) == .committed)
        #expect(try await memory.facts.conclude(conclusion) == .alreadyApplied, "a retried conclusion is the same fact")
        #expect(try await memory.count("SELECT count(*) FROM memory_operation_verifications") == 1)

        #expect(try await memory.calls.call("c1")?.progress.status == .completed)
        let effect = try #require(try await memory.facts.effect(of: "c1"))
        #expect(effect.performed == .requested && effect.checked && effect.target?.label == "Export")
        let verifications = try await memory.facts.verifications(of: "c1")
        #expect(verifications.count == 1)
        let read = try #require(verifications.first)
        #expect(read.check == conclusion.verifications[0].check,
                "condition, method, verdict, texts, limits and target as given")
        #expect(read.samples.map(\.phase) == [.before, .after])
        #expect(read.event.kind == .verification && read.event.traceID == "message-1")
        let stored = try #require(
            try await SQLiteVerificationRepository(store: memory.store).verification(read.event.eventID)
        )
        #expect(stored.record.scope == .call && stored.record.method == .sceneDifference
                && stored.record.verdict == .passed)
        #expect(try await memory.facts.attribution(of: "c1") == attribution)
        #expect(try await memory.tasks.calls(of: "attempt-1", for: TaskFixtures.producer) == ["c1"])
        await memory.store.close()
    }

    @Test("an unknown verdict stays unknown with its limits; a call with no check reports an explicit gap, never a pass")
    func unknownStaysUnknown() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(
            try OperationOpening(call: try Self.click("c2"), startedAtMS: TaskFixtures.t0 + 1)
        )
        let unknown = OperationCheck(
            condition: .structuralEffect,
            method: .sceneDifference,
            verdict: .unknown,
            limits: [.unattributed, .noExpectation],
            performed: .requested
        )
        let conclusion = try OperationConclusion(
            end: AgentCallTransition(
                "c2",
                AgentCallProgress(
                    .completed,
                    result: .outcome(.actedUnverified, message: "no change"),
                    endedAtMS: TaskFixtures.t0 + 2
                )
            ),
            effect: try OperationEffect(callEventID: "c2", performed: .requested, checked: true),
            verifications: [try Self.verification("c2", unknown, samples: [])]
        )
        _ = try await memory.facts.conclude(conclusion)
        let read = try #require(try await memory.facts.verifications(of: "c2").first)
        #expect(read.check.verdict == .unknown && read.check.limits == [.unattributed, .noExpectation])

        _ = try await memory.facts.open(
            try OperationOpening(call: try Self.click("c3"), startedAtMS: TaskFixtures.t0 + 3)
        )
        _ = try await memory.facts.conclude(try OperationConclusion(
            end: AgentCallTransition(
                "c3",
                AgentCallProgress(
                    .completed,
                    result: .outcome(.actedUnverified, message: "?"),
                    endedAtMS: TaskFixtures.t0 + 4
                )
            ),
            effect: try OperationEffect(callEventID: "c3", performed: .requested, checked: false)
        ))
        #expect(try await memory.facts.effect(of: "c3")?.checked == false)
        #expect(try await memory.facts.verifications(of: "c3").isEmpty)
        await memory.store.close()
    }

    @Test("another end, effect or verification under a stored identity is a conflict, and the whole conclusion writes nothing")
    func conflictsWriteNothing() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(
            try OperationOpening(call: try Self.click("c4"), startedAtMS: TaskFixtures.t0 + 1)
        )
        _ = try await memory.facts.conclude(try Self.conclusion("c4", verdict: .passed))
        let before = try await memory.count("SELECT count(*) FROM memory_event_observations")
        await #expect(throws: (any Error).self) {
            _ = try await memory.facts.conclude(try Self.conclusion("c4", verdict: .failed))
        }
        #expect(try await memory.count("SELECT count(*) FROM memory_event_observations") == before)
        #expect(try await memory.facts.verifications(of: "c4").first?.check.verdict == .passed)
        await memory.store.close()
    }

    @Test("a call attributed to an attempt that is no longer running is refused before anything is written")
    func attributionNeedsRunningAttempt() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        _ = try await memory.tasks.checkpoint(
            try TaskCheckpointDraft(kind: .end, declared: .completed),
            attempt: "attempt-1",
            at: TaskFixtures.t0 + 1,
            by: TaskFixtures.producer
        )
        let late = try OperationOpening(
            call: try Self.click("c5"),
            startedAtMS: TaskFixtures.t0 + 2,
            attribution: try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        )
        await #expect(throws: OperationFactError.attemptNotRunning(attemptID: "attempt-1")) {
            _ = try await memory.facts.open(late)
        }
        #expect(try await memory.calls.call("c5") == nil, "the call was not written: no gesture may follow")
        await memory.store.close()
    }

    @Test("a verification that names a sample the conclusion did not bring and the archive does not hold is refused whole")
    func verificationNeedsItsSamples() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(
            try OperationOpening(call: try Self.click("c6"), startedAtMS: TaskFixtures.t0 + 1)
        )
        let check = OperationCheck(
            condition: .structuralEffect,
            method: .sceneDifference,
            verdict: .passed,
            performed: .requested
        )
        let missing = CaptureSampleKey(eventID: "c6", phase: .after)
        let conclusion = try OperationConclusion(
            end: AgentCallTransition(
                "c6",
                AgentCallProgress(
                    .completed,
                    result: .outcome(.foundActed, message: "ok"),
                    endedAtMS: TaskFixtures.t0 + 2
                )
            ),
            verifications: [try Self.verification("c6", check, samples: [missing])]
        )
        await #expect(throws: AgentCallError.missingSample(eventID: "c6", sample: missing)) {
            _ = try await memory.facts.conclude(conclusion)
        }
        #expect(try await memory.calls.call("c6")?.progress.status == .started, "the end was not written either")
        await memory.store.close()
    }

    @Test("a value withheld at the opening is a declared gap; a value the conclusion withdraws is replaced by the marker, once")
    func withheldValues() async throws {
        let memory = try await TaskFixtures.open()
        let typing = try AgentCallRecord(
            event: Self.event("c7"),
            request: .typeText(target: "Password", text: ValueMinimization.marker, section: nil, replace: true)
        )
        let gap = ValueRedaction(eventID: "c7", location: .argument(name: "text", position: 0), reason: .secretTarget)
        _ = try await memory.facts.open(
            try OperationOpening(call: typing, startedAtMS: TaskFixtures.t0 + 1, redactions: [gap])
        )
        #expect(try await memory.facts.redactions(of: "c7") == [gap])

        let kept = try AgentCallRecord(
            event: Self.event("c8"),
            request: .insertText(text: "s3cr3t-value", expectedValue: nil)
        )
        _ = try await memory.facts.open(try OperationOpening(call: kept, startedAtMS: TaskFixtures.t0 + 2))
        let withdrawal = ValueRedaction(
            eventID: "c8",
            location: .argument(name: "text", position: 0),
            reason: .secureField
        )
        let end = try OperationConclusion(
            end: AgentCallTransition(
                "c8",
                AgentCallProgress(
                    .completed,
                    result: .outcome(.actedUnverified, message: "inserted"),
                    endedAtMS: TaskFixtures.t0 + 3
                )
            ),
            withdrawn: [withdrawal]
        )
        #expect(try await memory.facts.conclude(end) == .committed)
        #expect(try await memory.facts.conclude(end) == .alreadyApplied)
        let call = try #require(try await memory.calls.call("c8"))
        if case .insertText(let text, _) = call.request {
            #expect(text == ValueMinimization.marker)
        } else {
            Issue.record("not insert_text")
        }
        #expect(try await memory.count("""
            SELECT count(*) FROM memory_operation_arguments WHERE text_value = 's3cr3t-value'
            """) == 0)
        #expect(try await memory.facts.redactions(of: "c8") == [withdrawal])
        await memory.store.close()
    }

    @Test("a batch opens with its steps planned under the attempt as a container; each started step joins the attempt as an operation")
    func batchAttribution() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let attribution = try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        let (batch, steps) = try AgentCallFixtures.batch(
            "b1",
            [.act(target: "A", verb: .click, value: nil, section: nil),
             .act(target: "B", verb: .click, value: nil, section: nil)]
        )
        _ = try await memory.facts.open(
            batch: try BatchOpening(
                batch: batch,
                steps: steps,
                startedAtMS: AgentCallFixtures.t0,
                attribution: attribution
            )
        )
        _ = try await memory.facts.start(step: "b1.0", atMS: AgentCallFixtures.t0 + 1, attribution: attribution)
        let memberships = try await SQLiteTaskRepository(store: memory.store).memberships(of: "attempt-1")
        #expect(memberships.map(\.eventID) == ["b1", "b1.0"] && memberships.map(\.role) == [.context, .action])
        #expect(try await memory.facts.attribution(of: "b1.1") == nil,
                "a step that never started is not an operation of the attempt")
        await memory.store.close()
    }
}

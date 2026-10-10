//
//  CommandLineBatchTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import Memory
@testable import mecum
@testable import SQLiteMemory
import Testing

/// How `mecum batch` is recorded (review F05 of plan D1): one batch call with its steps planned under it,
/// each step started before it acts and ended by its command, the steps never run skipped, and the
/// batch's end with the summary its steps allow. The steps here are the commands' recording without a
/// Seat: each counts its gesture and ends its call as `ActCommand` and `SelectCommand` do.
@Suite("mecum batch recorded as one batch with its steps")
struct CommandLineBatchTests {

    private let app = AppContextIdentity(bundleID: "com.apple.TextEdit")

    private func plan() throws -> BatchPlan {
        try BatchPlan(arguments: ["batch", "TextEdit", "--window", "Untitled", "--seat", "--",
                                  "act", "Save", "--then", "select", "Format", "Bold", "--then", "act", "Close"])
    }

    /// A memory of its own, whose lock budget is short so a held lock refuses fast.
    private func memory() -> MemoryService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-line-batch-\(UUID().uuidString)", isDirectory: true)
        let store = SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(100),
            retryPause: .milliseconds(5),
            maximumRetryPause: .milliseconds(10)
        )
        return MemoryService(
            directory: directory,
            configuration: MemoryService.Configuration(store: store, essentialAttempts: 1, essentialCycles: 1)
        )
    }

    private func recorders(_ memory: MemoryService, count: Int) -> (parent: CallRecorder, children: [CallRecorder]) {
        let brain  = BrainMemory(brains: memory, applications: memory, clock: { memory.clock.brainNow() })
        // The context every command line call of the process has.
        let parent = CallRecorder(memory: memory, brain: brain, context: CommandLineTrace.context())
        let children = (0..<count).map {
            CallRecorder(memory: memory, brain: brain, context: parent.context.child($0))
        }
        return (parent, children)
    }

    private func status(_ memory: MemoryService, _ recorder: CallRecorder) async throws -> AgentCallStatus? {
        try await memory.call(recorder.eventID)?.progress.status
    }

    @Test("a command line call names its process's session, so the contract admits it: an act begins and ends")
    func commandLineCallHasASession() async throws {
        let memory   = memory()
        let recorder = recorders(memory, count: 0).parent
        try await recorder.begin(.act(target: "Save", verb: .click, value: nil, section: nil), app: app)
        try await CommandLineCall.end(recorder, outcome: ActOutcome(.foundActed, "clicked"), tool: .act)
        #expect(try await status(memory, recorder) == .completed)
        #expect(try await memory.event(recorder.eventID)?.sessionID == CommandLineTrace.session)
        await memory.close()
    }

    @Test("three steps planned, the second failing: one completed, one failed, one skipped, all under one batch whose end says so; no gesture for the third and no check on the batch")
    func stopAtTheSecondStep() async throws {
        let memory = memory()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        var gestures: [String] = []
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children) {
                number, step, recorder in
                gestures.append(step.summary)
                if number == 2 {
                    try? await recorder.end(.failed, result: .error(message: "the menu did not open"), tool: .select)
                    throw AutomationFailure("the menu did not open")
                }
                try await CommandLineCall.end(recorder, outcome: ActOutcome(.foundActed, "clicked"), tool: .act)
                return .foundActed
            }
            Issue.record("the batch did not stop")
        } catch is BatchFailure {}
        #expect(gestures.count == 2, "the third step never acted")
        #expect(try await status(memory, children[0]) == .completed)
        #expect(try await status(memory, children[1]) == .failed)
        #expect(try await status(memory, children[2]) == .skipped)
        for child in children {
            #expect(try await memory.event(child.eventID)?.parentEventID == parent.eventID)
        }
        let batch = try #require(try await memory.call(parent.eventID))
        #expect(batch.progress.status == .completed)
        guard case .batch(let stopped, let attempted, let verified)? = batch.progress.result else {
            Issue.record("the batch's end has no summary: \(String(describing: batch.progress.result))")
            return
        }
        #expect(stopped && attempted == 2 && verified == 1)
        #expect(try await memory.perform { try await $0.facts.verifications(of: parent.eventID) }.isEmpty,
                "the container proves nothing itself")
        await memory.close()
    }

    @Test("a step that answers without its effect stops the batch: completed with that outcome, the rest skipped")
    func stopOnAnUnacceptedOutcome() async throws {
        let memory = memory()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children) { number, _, recorder in
                let kind: ActOutcomeKind = number == 2 ? .honestMiss : .foundActed
                try await CommandLineCall.end(recorder, outcome: ActOutcome(kind, "answered"),
                                              tool: number == 2 ? .select : .act)
                return kind
            }
            Issue.record("the batch did not stop")
        } catch is BatchFailure {}
        #expect(try await status(memory, children[1]) == .completed)
        #expect(try await status(memory, children[2]) == .skipped)
        #expect(try await status(memory, parent) == .completed)
        await memory.close()
    }

    @Test("a batch the memory does not confirm does nothing and leaves nothing behind")
    func unconfirmedBatchDoesNothing() async throws {
        let memory = memory()
        _ = try await memory.ready()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        let lock = try SQLiteConnection(path: memory.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        var gestures = 0
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children) { _, _, _ in
                gestures += 1
                return .foundActed
            }
            Issue.record("the batch ran unconfirmed")
        } catch let failure as ActFailure {
            #expect(failure.kind == .refused)
        }
        try lock.execute("COMMIT")
        lock.close()
        #expect(gestures == 0)
        #expect(try await memory.calls(inTrace: CommandLineTrace.trace).isEmpty)
        await memory.close()
    }

    @Test("a step whose end is not saved stops the batch: nothing is repeated, the later steps never run, and the records left say incomplete")
    func unsavedStepEnd() async throws {
        let memory = memory()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        var lock: SQLiteConnection?
        var gestures = 0
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children) { number, _, recorder in
                gestures += 1
                if number == 2 {
                    lock = try SQLiteConnection(path: memory.url.path)
                    try lock?.execute("BEGIN IMMEDIATE")
                }
                try await CommandLineCall.end(recorder, outcome: ActOutcome(.foundActed, "clicked"),
                                              tool: number == 2 ? .select : .act)
                return .foundActed
            }
            Issue.record("the batch went on after an unsaved end")
        } catch let failure as BatchFailure {
            #expect(failure.cause is CommandLineCall.Unsaved)
        }
        try lock?.execute("COMMIT")
        lock?.close()
        #expect(gestures == 2)
        #expect(await memory.status().suspended != nil)
        await memory.close()

        let reopened = MemoryService(directory: memory.directory)
        #expect(try await reopened.call(parent.eventID)?.progress.status == .started, "the batch stays incomplete")
        #expect(try await reopened.call(children[0].eventID)?.progress.status == .completed)
        #expect(try await reopened.call(children[1].eventID)?.progress.status == .started)
        #expect(try await reopened.call(children[2].eventID)?.progress.status == .planned)
        await reopened.close()
    }
}

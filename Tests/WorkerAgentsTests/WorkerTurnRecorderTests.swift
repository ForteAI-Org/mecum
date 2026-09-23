//
//  WorkerTurnRecorderTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ChatCore
import Foundation
import ModelTransports
import Testing
import WorkerAgents
import Workspace

/// Each row replays a recorded event sequence through the recorder into a
/// real store in its own directory, then reads back what a view would show.
@MainActor
@Suite("A worker's turn in the workspace")
struct WorkerTurnRecorderTests {

    @Test func repliesBecomeWorkerMessagesAndToolRecordsBecomeToolRows() async throws {
        let fixture = try await Fixture()
        defer { fixture.discard() }
        var runs = 0
        let ending = try await fixture.recorder.run { selection, _, emit in
            runs += 1
            #expect(selection == Fixture.selection)
            emit(.provider(.session("session-1")))
            emit(.tool(#"→ windows {}"#))
            emit(.tool(#"← windows {"applications":[]}"#))
            emit(.provider(.assistant("Finder has one window.")))
            emit(.provider(.assistant("Nothing else is open.")))
            emit(.provider(.completed))
        }
        #expect(ending == .completed)
        #expect(runs == 1)

        let messages = try await fixture.store.messages(in: fixture.conversation)
        #expect(messages.map(\.text) == ["Which apps have windows?", "Finder has one window.", "Nothing else is open."])
        #expect(messages.dropFirst().allSatisfy { $0.authorWorkerID == fixture.worker && $0.delivery == .completed })
        #expect(messages.first?.delivery == .completed)

        let events = try await fixture.events()
        #expect(events.map(\.type) == [.executionStarted, .toolActivity, .toolActivity, .executionCompleted])
        #expect(events.compactMap(WorkerTurnRecorder.text(of:)) == [#"→ windows {}"#, #"← windows {"applications":[]}"#])
        #expect(events.allSatisfy { $0.correlationID == fixture.message && $0.workerID == fixture.worker })
    }

    @Test func aFailureIsRecordedOnceAndNotRetried() async throws {
        let fixture = try await Fixture()
        defer { fixture.discard() }
        var runs = 0
        let ending = try await fixture.recorder.run { _, _, emit in
            runs += 1
            emit(.provider(.assistant("Starting.")))
            emit(.provider(.failure("usage limit reached")))
            throw NSError(domain: "MecumProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "usage limit reached"])
        }
        #expect(ending == .failed(reason: "usage limit reached"))
        #expect(runs == 1)

        let events = try await fixture.events()
        #expect(events.filter { $0.type == .executionFailed }.count == 1)
        #expect(events.filter(\.type.isTerminal).count == 1)
        #expect(events.last.flatMap(WorkerTurnRecorder.text(of:)) == "usage limit reached")

        // What arrived before the failure stays, and the person's message reads interrupted.
        let messages = try await fixture.store.messages(in: fixture.conversation)
        #expect(messages.map(\.text) == ["Which apps have windows?", "Starting."])
        #expect(messages.first?.delivery == .interrupted)
    }

    @Test func aStopRecordsACancellationWithTheInterruptionNote() async throws {
        let fixture = try await Fixture()
        defer { fixture.discard() }
        let ending = try await fixture.recorder.run { _, _, emit in
            emit(.tool(#"→ status {}"#))
            throw CancellationError()
        }
        #expect(ending == .cancelled)

        let events = try await fixture.events()
        #expect(events.map(\.type) == [.executionStarted, .toolActivity, .executionCancelled])
        #expect(events.last.flatMap(WorkerTurnRecorder.text(of:)) == WorkerTurnRecorder.interruptedNote)
        #expect(WorkerTurnRecorder.interruptedNote == "Interrupted. Inspect the current app state before continuing.")
        #expect(try await fixture.store.messages(in: fixture.conversation).first?.delivery == .interrupted)
    }

    @Test func anUnconfiguredWorkerRunsNothingAndLeavesTheMessageAlone() async throws {
        let fixture = try await Fixture(configured: false)
        defer { fixture.discard() }
        var runs = 0
        await #expect(throws: WorkspaceStoreError.self) {
            _ = try await fixture.recorder.run { _, _, _ in runs += 1 }
        }
        #expect(runs == 0)
        #expect(try await fixture.events().isEmpty)
        #expect(try await fixture.store.messages(in: fixture.conversation).first?.delivery == .savedLocally)
    }
}

/// One worker, its direct conversation and the person's first message, in a
/// store of its own.
@MainActor
private struct Fixture {

    static let selection = ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low)

    let directory   : URL
    let store       : WorkspaceStore
    let worker      : UUID
    let conversation: UUID
    let message     : UUID
    let recorder    : WorkerTurnRecorder

    init(configured: Bool = true) async throws {
        directory = URL.temporaryDirectory.appending(path: "WorkerAgentsTests-\(UUID().uuidString)",
                                                     directoryHint: .isDirectory)
        store = try WorkspaceStore.opening(in: directory)
        let appearance = WorkerAppearance(seed: 7, generatorVersion: 3, palette: "dusk",
                                          roundness: 0.5, wobble: 0.5, glow: 0.5)
        worker = try await store.createWorker(name: "Nova", appearance: appearance).id
        if configured { try await store.configure(worker: worker, selection: Self.selection) }
        conversation = try await store.createConversation(kind: .direct, participants: [worker]).id
        message = try await store.appendMessage(to: conversation, text: "Which apps have windows?").id
        recorder = WorkerTurnRecorder(store: store, workspaceID: UUID(), workerID: worker,
                                      conversationID: conversation, messageID: message) {}
    }

    func events() async throws -> [RecordedEvent] {
        try await store.events(matching: EventQuery(scope: .conversation(conversation)))
    }

    /// A failure here must not fail the row it cleans up after; the directory
    /// is under the system temporary directory, which the system reclaims.
    func discard() {
        do { try FileManager.default.removeItem(at: directory) } catch {}
    }
}

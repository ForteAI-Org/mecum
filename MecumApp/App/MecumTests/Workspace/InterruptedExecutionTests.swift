//
//  InterruptedExecutionTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import SQLite3
import Testing
@testable import Mecum

/// A crash is simulated by writing what a turn writes up to some point with
/// one store instance and opening the directory again with another, as the
/// next launch does.
@Suite("A turn a crash left unfinished")
struct InterruptedExecutionTests {

    private static let reason    = "The app closed during this turn."
    private static let workspace = UUID()

    @Test("It is ended once, as failed, and a second launch changes nothing")
    func anUnfinishedTurnEndsOnceAndStaysEnded() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let crashed = try WorkspaceStore.opening(in: directory)
        let turn    = try await Turn(in: crashed)
        try await crashed.update(message: turn.message, delivery: .sentToBackend)
        try await crashed.appendMessage(to: turn.conversation, author: turn.worker, text: "Half of it",
                                        delivery: .completed)
        try await crashed.update(message: turn.message, delivery: .responding)
        let messagesBefore = try await crashed.messages(in: turn.conversation)

        let relaunched = try WorkspaceStore.opening(in: directory)
        let ended = try await relaunched.endExecutionsLeftUnfinished(reason: Self.reason, workspace: Self.workspace)
        #expect(ended == [turn.execution])

        let events = try await relaunched.events(matching: EventQuery(scope: .subject(turn.execution)))
        #expect(events.map(\.type) == [.executionStarted, .executionFailed])
        let failure = try #require(events.last)
        #expect(failure.payload == Data(Self.reason.utf8))
        #expect(failure.correlationID == turn.message)
        #expect(failure.workspaceID == turn.workspace)
        #expect(failure.conversationID == turn.conversation)

        // The partial reply stays as it was, and only the person's message changes.
        let messagesAfter = try await relaunched.messages(in: turn.conversation)
        #expect(messagesAfter.map(\.text) == messagesBefore.map(\.text))
        #expect(messagesAfter.map(\.delivery) == [.interrupted, .completed])

        // Nothing is retried: the whole record gained the one ending and nothing else.
        let record = try await relaunched.events(matching: EventQuery(scope: .workspace(turn.workspace)))
        #expect(record.map(\.type) == [.executionStarted, .executionFailed])

        // A second launch finds it ended; the same instance does not scan again.
        #expect(try await relaunched.endExecutionsLeftUnfinished(reason: Self.reason, workspace: Self.workspace)
                    .isEmpty)
        let again = try WorkspaceStore.opening(in: directory)
        #expect(try await again.endExecutionsLeftUnfinished(reason: "Another reason", workspace: UUID()).isEmpty)
        #expect(try await again.events(matching: EventQuery(scope: .workspace(turn.workspace))) == record)
        #expect(try await again.messages(in: turn.conversation) == messagesAfter)

        // A late ending from the turn itself lands on the one already recorded, first arrival wins.
        let late = try await again.append(NewEvent(workspaceID: turn.workspace, subjectID: turn.execution,
                                                   type: .executionCompleted))
        #expect(late == failure)
    }

    @Test("A turn this process started, or one that ended, is left alone")
    func aLiveOrFinishedTurnIsLeftAlone() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let earlier  = try WorkspaceStore.opening(in: directory)
        let finished = try await Turn(in: earlier)
        try await earlier.append(NewEvent(workspaceID: finished.workspace, subjectID: finished.execution,
                                          type: .executionCompleted, correlationID: finished.message))
        try await earlier.update(message: finished.message, delivery: .completed)

        let store = try WorkspaceStore.opening(in: directory)
        let live  = try await Turn(in: store)
        #expect(try await store.endExecutionsLeftUnfinished(reason: Self.reason, workspace: Self.workspace).isEmpty)

        let liveEvents = try await store.events(matching: EventQuery(scope: .subject(live.execution)))
        #expect(liveEvents.map(\.type) == [.executionStarted])
        #expect(try await store.message(live.message)?.delivery == .savedLocally)
        #expect(try await store.message(finished.message)?.delivery == .completed)
    }

    @Test("A turn that ended before its message was updated settles the message, once")
    func anEndedTurnSettlesItsMessage() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let crashed   = try WorkspaceStore.opening(in: directory)
        let completed = try await Turn(in: crashed)
        let stopped   = try await Turn(in: crashed)
        try await crashed.update(message: completed.message, delivery: .responding)
        try await crashed.update(message: stopped.message, delivery: .sentToBackend)
        try await crashed.append(NewEvent(workspaceID: completed.workspace, subjectID: completed.execution,
                                          type: .executionCompleted, correlationID: completed.message))
        try await crashed.append(NewEvent(workspaceID: stopped.workspace, subjectID: stopped.execution,
                                          type: .executionCancelled, correlationID: stopped.message))

        let relaunched = try WorkspaceStore.opening(in: directory)
        // A turn of this instance between its ending and its message update is its own to finish.
        let live = try await Turn(in: relaunched)
        try await relaunched.update(message: live.message, delivery: .responding)
        try await relaunched.append(NewEvent(workspaceID: live.workspace, subjectID: live.execution,
                                             type: .executionCompleted, correlationID: live.message))
        let before = try await Self.record(of: [completed, stopped, live], in: relaunched)

        #expect(try await relaunched.endExecutionsLeftUnfinished(reason: Self.reason, workspace: Self.workspace)
                    .isEmpty)
        #expect(try await relaunched.message(completed.message)?.delivery == .completed)
        #expect(try await relaunched.message(stopped.message)?.delivery == .interrupted)
        #expect(try await relaunched.message(live.message)?.delivery == .responding)
        #expect(try await Self.record(of: [completed, stopped, live], in: relaunched) == before)

        try await relaunched.update(message: live.message, delivery: .completed)
        let again = try WorkspaceStore.opening(in: directory)
        #expect(try await again.endExecutionsLeftUnfinished(reason: Self.reason, workspace: Self.workspace).isEmpty)
        #expect(try await again.message(completed.message)?.delivery == .completed)
        #expect(try await again.message(stopped.message)?.delivery == .interrupted)
        #expect(try await Self.record(of: [completed, stopped, live], in: again) == before)
    }

    @Test("A type this build does not know reads back as unknown and never ends a turn")
    func anUnknownTypeReadsBackAndIsNeverAnEnding() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let earlier  = try WorkspaceStore.opening(in: directory)
        let running  = try await Turn(in: earlier)
        let finished = try await Turn(in: earlier)
        try await earlier.update(message: finished.message, delivery: .responding)
        try await earlier.append(NewEvent(workspaceID: running.workspace, subjectID: running.execution,
                                          type: .toolActivity, correlationID: running.message))
        try await earlier.append(NewEvent(workspaceID: finished.workspace, subjectID: finished.execution,
                                          type: .executionCompleted, correlationID: finished.message))

        // What a newer build writes: a progress type, and an ending whose key stays terminal.
        let store = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(try Self.rewrite(store, type: "toolActivity", to: "taskProgressed") == 1)
        #expect(try Self.rewrite(store, type: "executionCompleted", to: "executionSuperseded") == 1)

        let relaunched = try WorkspaceStore.opening(in: directory)
        let progress = try await relaunched.events(matching: EventQuery(scope: .subject(running.execution)))
        let ending   = try await relaunched.events(matching: EventQuery(scope: .subject(finished.execution)))
        #expect(progress.map(\.type) == [.executionStarted, .unknown("taskProgressed")])
        #expect(ending.map(\.type) == [.executionStarted, .unknown("executionSuperseded")])
        #expect(!EventType.unknown("executionSuperseded").isTerminal)
        #expect(EventType(rawValue: "executionCompleted") == .executionCompleted)
        #expect(EventType.unknown("taskProgressed").rawValue == "taskProgressed")

        // The unknown progress row does not end its turn; the unknown ending's terminal key still does.
        let ended = try await relaunched.endExecutionsLeftUnfinished(reason: Self.reason, workspace: Self.workspace)
        #expect(ended == [running.execution])
        let recovered = try await relaunched.events(matching: EventQuery(scope: .subject(running.execution)))
        #expect(recovered.map(\.type) == [.executionStarted, .unknown("taskProgressed"), .executionFailed])
        #expect(try await relaunched.events(matching: EventQuery(scope: .subject(finished.execution))) == ending)
        #expect(try await relaunched.message(running.message)?.delivery == .interrupted)
        // An ending this build cannot read is not taken for a success.
        #expect(try await relaunched.message(finished.message)?.delivery == .interrupted)
    }

    @Test("A manager change an older build recorded reads back as unknown")
    func aManagerChangeRowReadsBackAsUnknown() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let earlier = try WorkspaceStore.opening(in: directory)
        let turn    = try await Turn(in: earlier)
        try await earlier.append(NewEvent(workspaceID: turn.workspace, subjectID: turn.execution,
                                          type: .toolActivity, correlationID: turn.message))

        // Builds before the flat team recorded a worker's move under its manager with this type.
        let store = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(try Self.rewrite(store, type: "toolActivity", to: "workerManagerChanged") == 1)

        let relaunched = try WorkspaceStore.opening(in: directory)
        let events = try await relaunched.events(matching: EventQuery(scope: .subject(turn.execution)))
        #expect(events.map(\.type) == [.executionStarted, .unknown("workerManagerChanged")])
    }

    @Test("A turn cut short before its start was recorded still ends, with no message to mark")
    func aTurnWithNoStartEventEndsInTheGivenWorkspace() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let crashed = try WorkspaceStore.opening(in: directory)
        let worker  = try await crashed.createWorker(name: "Nova", appearance: TemporaryStore.appearance()).id
        try await crashed.configure(worker: worker, selection: TemporaryStore.firstSelection)
        let execution = try await crashed.startExecution(worker: worker).id

        let relaunched = try WorkspaceStore.opening(in: directory)
        #expect(try await relaunched.endExecutionsLeftUnfinished(reason: Self.reason, workspace: Self.workspace)
                    == [execution])
        let events = try await relaunched.events(matching: EventQuery(scope: .subject(execution)))
        #expect(events.map(\.type) == [.executionFailed])
        #expect(events.first?.workspaceID == Self.workspace)
        #expect(events.first?.correlationID == nil)
    }

    /// Every event of the turns, in order, to compare a record before and after.
    private static func record(of turns: [Turn], in store: WorkspaceStore) async throws -> [RecordedEvent] {
        var events: [RecordedEvent] = []
        for turn in turns {
            events += try await store.events(matching: EventQuery(scope: .workspace(turn.workspace)))
        }
        return events
    }

    /// Rewrites the stored type of the events of one type, straight in the
    /// store's database, and returns how many rows changed.
    private static func rewrite(_ store: URL, type old: String, to new: String) throws -> Int32 {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(store.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        let statement = "UPDATE ZWORKSPACEEVENT SET ZTYPE = '\(new)' WHERE ZTYPE = '\(old)'"
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        return sqlite3_changes(database)
    }
}

/// What `WorkerTurnRecorder` has written when its turn is running: the
/// execution, its `executionStarted` and the person's message it answers.
private struct Turn {

    let workspace    = UUID()
    let worker       : UUID
    let conversation : UUID
    let message      : UUID
    let execution    : UUID

    init(in store: WorkspaceStore) async throws {
        worker = try await store.createWorker(name: "Nova", appearance: TemporaryStore.appearance()).id
        try await store.configure(worker: worker, selection: TemporaryStore.firstSelection)
        conversation = try await store.createConversation(kind: .direct, participants: [worker]).id
        message      = try await store.appendMessage(to: conversation, text: "Open Notes").id
        execution    = try await store.startExecution(worker: worker, conversation: conversation).id
        try await store.append(NewEvent(workspaceID: workspace, subjectID: execution, conversationID: conversation,
                                        workerID: worker, type: .executionStarted, correlationID: message))
    }
}

//
//  EventStoreTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData
import Testing
@testable import Mecum

@Suite("The operational record")
struct EventStoreTests {

    @Test("The same terminal event appended twice lands once")
    func terminalEventIsIdempotent() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store     = try WorkspaceStore.opening(in: directory)
        let workspace = UUID()
        let execution = UUID()
        let worker    = UUID()

        let first = try await store.append(
            NewEvent(workspaceID: workspace, subjectID: execution, workerID: worker,
                     timestamp: Date(timeIntervalSince1970: 100), type: .executionCompleted)
        )

        // The second delivery is a different envelope carrying the same
        // result: new event id, new timestamp, same transition.
        let second = try await store.append(
            NewEvent(workspaceID: workspace, subjectID: execution, workerID: worker,
                     timestamp: Date(timeIntervalSince1970: 900), type: .executionCompleted)
        )

        let recorded = try await store.events(matching: EventQuery(scope: .subject(execution)))
        #expect(recorded.count == 1)
        #expect(second.id == first.id)
        #expect(second.localOrder == first.localOrder)
        #expect(second.timestamp == first.timestamp)

        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.events(matching: EventQuery(scope: .subject(execution))).count == 1)
    }

    @Test("An event that may repeat does repeat")
    func ordinaryEventsAreNotCollapsed() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store     = try WorkspaceStore.opening(in: directory)
        let workspace = UUID()
        let subject   = UUID()

        for _ in 1...3 {
            try await store.append(
                NewEvent(workspaceID: workspace, subjectID: subject, type: .messageDeliveryChanged)
            )
        }

        let recorded = try await store.events(matching: EventQuery(scope: .subject(subject)))
        #expect(recorded.count == 3)
        #expect(recorded.map(\.localOrder) == [1, 2, 3])
    }

    /// A tripwire, not a guarantee: SwiftData resolves a `#Unique` conflict by
    /// updating the row already there with the incoming values. First arrival
    /// is kept only by `WorkspaceStore.append`, which is why it is the only
    /// writer. If this starts failing, SwiftData changed how it resolves the
    /// conflict and the doc comments on `WorkspaceEvent` must change with it.
    @Test("The unique constraint keeps one row per key and the later write's values")
    func theConstraintUpdatesTheRowOnConflict() throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let container = try WorkspaceStoreFile.open(in: directory)
        let workspace = UUID()
        let execution = UUID()

        // Written straight into two contexts, past `WorkspaceStore.append` and
        // its check: only the unique constraint is left.
        let arrivals: [(EventType, TimeInterval)] = [(.executionCancelled, 100), (.executionCompleted, 900)]
        for (order, (type, seconds)) in arrivals.enumerated() {
            let context = ModelContext(container)
            let event   = NewEvent(workspaceID: workspace, subjectID: execution,
                                   timestamp: Date(timeIntervalSince1970: seconds), type: type)
            context.insert(WorkspaceEvent(event, localOrder: order + 1))
            try context.save()
        }

        let rows = try ModelContext(container).fetch(FetchDescriptor<WorkspaceEvent>())
        #expect(rows.count == 1)
        #expect(rows.first?.type == .executionCompleted)
        #expect(rows.first?.timestamp == Date(timeIntervalSince1970: 900))
    }

    @Test("A late notification does not reopen work that was cancelled")
    func lateTerminalDoesNotChangeTheOutcome() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store     = try WorkspaceStore.opening(in: directory)
        let workspace = UUID()
        let execution = UUID()

        let cancelled = try await store.append(
            NewEvent(workspaceID: workspace, subjectID: execution,
                     timestamp: Date(timeIntervalSince1970: 100), type: .executionCancelled)
        )

        // The provider reports the work finished after it was cancelled: a
        // different terminal type for the same execution.
        let late = try await store.append(
            NewEvent(workspaceID: workspace, subjectID: execution,
                     timestamp: Date(timeIntervalSince1970: 900), type: .executionCompleted)
        )

        let recorded = try await store.events(matching: EventQuery(scope: .subject(execution)))
        #expect(recorded.count == 1)
        #expect(recorded.first?.type == .executionCancelled)
        #expect(late.id == cancelled.id)
        #expect(late.type == .executionCancelled)
        #expect(late.timestamp == cancelled.timestamp)

        let reopened = try WorkspaceStore.opening(in: directory)
        let after    = try await reopened.events(matching: EventQuery(scope: .subject(execution)))
        #expect(after.map(\.type) == [.executionCancelled])
    }

    @Test("A second attempt is a second execution and ends on its own key")
    func aNewAttemptEndsOnItsOwnKey() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Atlas",
                                                  appearance: TemporaryStore.appearance())
        try await store.configure(worker: worker.id, selection: TemporaryStore.firstSelection)

        let workspace = UUID()
        let first     = try await store.startExecution(worker: worker.id)
        try await store.append(NewEvent(workspaceID: workspace, subjectID: first.id,
                                        workerID: worker.id, type: .executionFailed))

        // Reopening the work mints a new execution, which is what keeps its
        // ending off the previous attempt's key.
        let second = try await store.startExecution(worker: worker.id)
        #expect(second.id != first.id)
        try await store.append(NewEvent(workspaceID: workspace, subjectID: second.id,
                                        workerID: worker.id, type: .executionCompleted))

        let recorded = try await store.events(matching: EventQuery(scope: .worker(worker.id)))
        #expect(recorded.map(\.type) == [.executionFailed, .executionCompleted])
    }

    @Test("Events read back in local order, by worker and by conversation")
    func scopedReads() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store        = try WorkspaceStore.opening(in: directory)
        let workspace    = UUID()
        let atlas        = UUID()
        let nova         = UUID()
        let conversation = UUID()

        try await store.append(NewEvent(workspaceID: workspace, subjectID: atlas, workerID: atlas,
                                        type: .workerCreated))
        try await store.append(NewEvent(workspaceID: workspace, subjectID: nova, workerID: nova,
                                        type: .workerCreated))
        try await store.append(NewEvent(workspaceID: workspace, subjectID: conversation,
                                        conversationID: conversation, workerID: atlas,
                                        type: .conversationOpened))

        let all = try await store.events(matching: EventQuery(scope: .workspace(workspace)))
        #expect(all.map(\.localOrder) == [1, 2, 3])

        let byWorker = try await store.events(matching: EventQuery(scope: .worker(atlas)))
        #expect(byWorker.map(\.type) == [.workerCreated, .conversationOpened])

        let byConversation = try await store.events(
            matching: EventQuery(scope: .conversation(conversation))
        )
        #expect(byConversation.count == 1)

        let newestFirst = try await store.events(
            matching: EventQuery(scope: .workspace(workspace), isAscending: false, limit: 1)
        )
        #expect(newestFirst.map(\.localOrder) == [3])
    }
}

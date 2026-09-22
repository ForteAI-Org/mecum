//
//  EventStoreTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData
import Testing
@testable import Workspace

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

    @Test("The constraint is in the schema, not in the store's own check")
    func duplicateIsRefusedBelowTheStore() throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let container = try WorkspaceStoreFile.open(in: directory)
        let context   = ModelContext(container)
        let workspace = UUID()
        let execution = UUID()

        // Written straight into a context, past `WorkspaceStore.append` and
        // the short circuit it makes: only the unique constraint is left.
        for (order, type) in [EventType.executionCancelled, .executionCompleted].enumerated() {
            let event = NewEvent(workspaceID: workspace, subjectID: execution, type: type)
            context.insert(WorkspaceEvent(event, localOrder: order + 1))
        }
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<WorkspaceEvent>()) == 1)
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

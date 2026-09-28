//
//  WorkerStoreTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import SwiftData
import Testing
@testable import Mecum

@Suite("Workers and configuration")
struct WorkerStoreTests {

    @Test("Identity and appearance survive a reopen and every ordinary edit")
    func identityIsStable() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let appearance = TemporaryStore.appearance()
        let store      = try WorkspaceStore.opening(in: directory)
        let created    = try await store.createWorker(
            name      : "Nova",
            role      : "Research",
            appearance: appearance
        )

        #expect(created.isConfigured == false)

        try await store.update(worker: created.id, .name("Nova Rossi"))
        try await store.update(worker: created.id, .role("Editing"))
        try await store.update(worker: created.id, .instructions("Prefers short answers."))
        try await store.configure(worker: created.id, selection: TemporaryStore.firstSelection)
        try await store.configure(worker: created.id, selection: TemporaryStore.secondSelection)

        let reopened = try WorkspaceStore.opening(in: directory)
        let read     = try #require(try await reopened.worker(created.id))

        #expect(read.id == created.id)
        #expect(read.appearance == appearance)
        #expect(read.appearance.seed == Int64(bitPattern: 0xDEAD_BEEF_CAFE_F00D))
        #expect(read.name == "Nova Rossi")
        #expect(read.role == "Editing")
        #expect(read.configuration == TemporaryStore.secondSelection)
        #expect(read.configurationVersion == 2)
        #expect(read.isConfigured)
    }

    @Test("An execution keeps the configuration it ran with")
    func executionSnapshotIsNotRewritten() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Atlas", appearance: TemporaryStore.appearance())

        await #expect(throws: WorkspaceStoreError.self) {
            try await store.startExecution(worker: worker.id)
        }

        try await store.configure(worker: worker.id, selection: TemporaryStore.firstSelection)
        let execution = try await store.startExecution(worker: worker.id)
        #expect(execution.selection == TemporaryStore.firstSelection)
        #expect(execution.configurationVersion == 1)

        try await store.configure(worker: worker.id, selection: TemporaryStore.secondSelection)

        let reopened = try WorkspaceStore.opening(in: directory)
        let read     = try #require(try await reopened.execution(execution.id))
        #expect(read.selection == TemporaryStore.firstSelection)
        #expect(read.configurationVersion == 1)
        #expect(try await reopened.worker(worker.id)?.configuration == TemporaryStore.secondSelection)
    }

    @Test("Changing the model writes a new version and leaves the old one on disk")
    func reconfiguringKeepsEveryVersion() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Iris", appearance: TemporaryStore.appearance())

        #expect(try await store.configure(worker: worker.id, selection: TemporaryStore.firstSelection) == 1)
        #expect(try await store.configure(worker: worker.id, selection: TemporaryStore.secondSelection) == 2)
        #expect(try await store.worker(worker.id)?.configurationVersion == 2)

        // Read the rows themselves, from a separate container, so the old
        // version is proven to be on disk and not only in the actor's context.
        let context  = ModelContext(try WorkspaceStoreFile.open(in: directory))
        let workerID = worker.id
        let rows     = try context.fetch(
            FetchDescriptor<WorkerConfiguration>(
                predicate: #Predicate { $0.workerID == workerID },
                sortBy   : [SortDescriptor(\.version)]
            )
        )
        #expect(rows.map(\.version) == [1, 2])
        #expect(rows.map(\.selection) == [TemporaryStore.firstSelection, TemporaryStore.secondSelection])
    }

    @Test("Archiving leaves the worker readable and out of the active team")
    func archiving() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Milo", appearance: TemporaryStore.appearance())
        try await store.update(worker: worker.id, .archived(true))

        #expect(try await store.workers().isEmpty)
        #expect(try await store.workers(includingArchived: true).count == 1)
        #expect(try await store.worker(worker.id)?.isArchived == true)
    }

    @Test("Deleting a worker takes its conversation, history and record with it, and nothing of another's")
    func deleting() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store     = try WorkspaceStore.opening(in: directory)
        let workspace = UUID()

        // Two workers with the same history each: a version, a conversation with a message, a turn and its event.
        var histories: [(worker: UUID, conversation: UUID)] = []
        for name in ["Nova", "Atlas"] {
            let worker = try await store.createWorker(
                name      : name,
                appearance: TemporaryStore.appearance()
            )
            try await store.configure(
                worker   : worker.id,
                selection: TemporaryStore.firstSelection
            )
            let conversation = try await store.createConversation(participants: [worker.id])
            try await store.appendMessage(
                to  : conversation.id,
                text: "Hello, \(name)."
            )
            let execution = try await store.startExecution(
                worker      : worker.id,
                conversation: conversation.id
            )
            try await store.append(NewEvent(
                workspaceID   : workspace,
                subjectID     : execution.id,
                conversationID: conversation.id,
                workerID      : worker.id,
                type          : .executionCompleted
            ))
            histories.append((worker.id, conversation.id))
        }
        let (deleted, kept) = (histories[0], histories[1])

        #expect(try await store.deleteWorker(deleted.worker) == [deleted.conversation])

        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.worker(deleted.worker) == nil)
        #expect(try await reopened.conversation(deleted.conversation) == nil)
        #expect(try await reopened.messages(in: deleted.conversation).isEmpty)
        #expect(try await reopened.latestExecution(of: deleted.worker) == nil)
        #expect(try await reopened.events(matching: EventQuery(scope: .worker(deleted.worker))).isEmpty)
        #expect(try await reopened.events(matching: EventQuery(scope: .conversation(deleted.conversation))).isEmpty)

        let context  = ModelContext(try WorkspaceStoreFile.open(in: directory))
        let workerID = deleted.worker
        #expect(try context.fetchCount(FetchDescriptor<WorkerConfiguration>(
            predicate: #Predicate { $0.workerID == workerID }
        )) == 0)

        #expect(try await reopened.worker(kept.worker)?.configurationVersion == 1)
        #expect(try await reopened.messages(in: kept.conversation).count == 1)
        #expect(try await reopened.latestExecution(of: kept.worker) != nil)
        #expect(try await reopened.events(matching: EventQuery(scope: .worker(kept.worker))).count == 1)
    }
}

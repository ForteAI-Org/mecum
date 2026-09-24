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
}

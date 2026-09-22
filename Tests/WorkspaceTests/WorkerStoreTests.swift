//
//  WorkerStoreTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import Testing
import Workspace

@Suite("Workers, hierarchy and configuration")
struct WorkerStoreTests {

    @Test("Several workers sit at the root and a worker may have no manager")
    func rootsAndOrphans() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let atlas = try await store.createWorker(name: "Atlas", appearance: TemporaryStore.appearance())
        let nova  = try await store.createWorker(name: "Nova", appearance: TemporaryStore.appearance())
        let milo  = try await store.createWorker(name: "Milo", managerID: atlas.id,
                                                 appearance: TemporaryStore.appearance())

        #expect(atlas.managerID == nil)
        #expect(nova.managerID == nil)
        #expect(milo.managerID == atlas.id)

        let roots = try await store.workers().filter { $0.managerID == nil }
        #expect(roots.count == 2)
    }

    @Test("A move that would close a loop is refused before the save")
    func refusesCycle() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let atlas = try await store.createWorker(name: "Atlas", appearance: TemporaryStore.appearance())
        let milo  = try await store.createWorker(name: "Milo", managerID: atlas.id,
                                                 appearance: TemporaryStore.appearance())
        let iris  = try await store.createWorker(name: "Iris", managerID: milo.id,
                                                 appearance: TemporaryStore.appearance())

        await #expect(throws: WorkspaceStoreError.self) {
            try await store.update(worker: atlas.id, .manager(iris.id))
        }
        await #expect(throws: WorkspaceStoreError.self) {
            try await store.update(worker: atlas.id, .manager(atlas.id))
        }

        // The refusal happens before anything is written, so the store still
        // holds the hierarchy it had, in this process and after a reopen.
        #expect(try await store.worker(atlas.id)?.managerID == nil)

        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.worker(atlas.id)?.managerID == nil)
        #expect(try await reopened.worker(iris.id)?.managerID == milo.id)
    }

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

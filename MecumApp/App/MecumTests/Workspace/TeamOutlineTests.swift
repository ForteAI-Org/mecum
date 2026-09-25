//
//  TeamOutlineTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// What the sidebar shows, checked without a view.
///
/// The snapshots come from a real store because `WorkerSnapshot` is made by
/// the store and stays that way; what is under test is the ordering and the
/// two texts, not the persistence, which `WorkerStoreTests` already covers.
@Suite("Team outline and row texts")
struct TeamOutlineTests {

    @Test("The team is one flat list, in the store's order by name")
    func theTeamIsFlatByName() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let last  = try await store.createWorker(name: "Zzz", appearance: TemporaryStore.appearance())
        let first = try await store.createWorker(name: "Aaa", appearance: TemporaryStore.appearance())
        let mid   = try await store.createWorker(name: "Bbb", appearance: TemporaryStore.appearance())

        let rows = TeamOutline.rows(of: try await store.workers())

        #expect(rows.map(\.id) == [first.id, mid.id, last.id])
    }

    @Test("A worker whose model is gone keeps its place and reads as to configure")
    func aMissingModelKeepsThePlace() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let head  = try await store.createWorker(name: "Aaa", role: "Lead", appearance: TemporaryStore.appearance())
        let gone  = try await store.createWorker(name: "Bbb", role: "Research",
                                                 appearance: TemporaryStore.appearance())
        try await store.configure(worker: head.id, selection: TemporaryStore.firstSelection)
        try await store.configure(worker: gone.id, selection: TemporaryStore.secondSelection)

        let workers = try await store.workers()
        let before  = TeamOutline.rows(of: workers)
        let after   = TeamOutline.rows(of: workers, modelUnavailable: [gone.id])

        #expect(before.map(\.id) == after.map(\.id))

        let row = try #require(after.first { $0.id == gone.id })
        #expect(row.worker.isConfigured)
        #expect(row.needsConfiguring)
        #expect(row.subtitle == TeamRow.toConfigure)
        #expect(row.accessibilityLabel.contains(TeamRow.toConfigure))
        #expect(!row.accessibilityLabel.contains(TemporaryStore.secondSelection.model))
        #expect(after.first { $0.id == head.id }?.subtitle == "claude-opus-5, High Effort")
    }

    @Test("Changing a worker's state does not move it in the list")
    func stateDoesNotReorder() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        _         = try await store.createWorker(name: "Aaa", appearance: TemporaryStore.appearance())
        let first = try await store.createWorker(name: "Bbb", appearance: TemporaryStore.appearance())
        _         = try await store.createWorker(name: "Ccc", appearance: TemporaryStore.appearance())

        let before = TeamOutline.rows(of: try await store.workers())
        try await store.configure(worker: first.id, selection: TemporaryStore.firstSelection)
        let after = TeamOutline.rows(of: try await store.workers())

        #expect(before.map(\.id) == after.map(\.id))
        #expect(after.first { $0.id == first.id }?.worker.isConfigured == true)
    }

    @Test("The subtitle is the model, and says to configure while no model is attached")
    func subtitleChoosesModelOrConfiguration() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store   = try WorkspaceStore.opening(in: directory)
        let roled   = try await store.createWorker(name: "Aaa", role: "Research lead",
                                                   appearance: TemporaryStore.appearance())
        let roleless = try await store.createWorker(name: "Bbb", role: "  ",
                                                    appearance: TemporaryStore.appearance())

        let unattached = TeamOutline.rows(of: try await store.workers())
        #expect(unattached.map(\.subtitle) == [TeamRow.toConfigure, TeamRow.toConfigure])

        try await store.configure(worker: roled.id, selection: TemporaryStore.firstSelection)
        try await store.configure(worker: roleless.id, selection: TemporaryStore.secondSelection)

        // The role stays in the label and the inspector; the second line is the model, and only that.
        let attached = TeamOutline.rows(of: try await store.workers())
        #expect(attached.first { $0.id == roled.id }?.subtitle == "claude-opus-5, High Effort")
        #expect(attached.first { $0.id == roleless.id }?.subtitle == "qwen3:8b, No thinking")
        #expect(attached.first { $0.id == roled.id }?.accessibilityLabel
            == "Aaa, Research lead, claude-opus-5, High Effort")
    }

    @Test("The accessible label keeps the whole name and the role behind a truncation")
    func accessibleLabelKeepsTheWholeName() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let long  = String(repeating: "Bartholomew ", count: 12)
        let store = try WorkspaceStore.opening(in: directory)
        let made  = try await store.createWorker(name: long, role: "Research lead",
                                                 appearance: TemporaryStore.appearance())

        guard let row = TeamOutline.rows(of: try await store.workers()).first else {
            Issue.record("the worker that was created is not in the outline")
            return
        }

        #expect(row.id == made.id)
        #expect(row.name == long)
        #expect(row.accessibilityLabel.hasPrefix(long))
        #expect(row.accessibilityLabel.contains("Research lead"))
        #expect(row.accessibilityLabel.contains(TeamRow.toConfigure))
    }

    @Test("An activity replaces the model in the subtitle and never moves the row")
    func anActivityReplacesTheModelAndKeepsTheOrder() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let head  = try await store.createWorker(name: "Aaa", role: "Lead", appearance: TemporaryStore.appearance())
        let scout = try await store.createWorker(name: "Bbb", role: "Scout", appearance: TemporaryStore.appearance())
        let idle  = try await store.createWorker(name: "Ccc", appearance: TemporaryStore.appearance())
        for worker in [head, scout] {
            try await store.configure(worker: worker.id, selection: TemporaryStore.firstSelection)
        }
        let workers = try await store.workers()

        let before = TeamOutline.rows(of: workers)
        let after  = TeamOutline.rows(of: workers, activities: [
            scout.id: "Waiting for the computer (1 ahead)", head.id: "Using Calculator", idle.id: "Using Notes"
        ])

        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.subtitle) == ["Using Calculator", "Waiting for the computer (1 ahead)", TeamRow.toConfigure])
        let model = "claude-opus-5, High Effort"
        #expect(before.map(\.subtitle) == [model, model, TeamRow.toConfigure])
        let scoutRow = try #require(after.first { $0.id == scout.id })
        #expect(scoutRow.accessibilityLabel
            == "Bbb, Scout, Waiting for the computer (1 ahead), \(model)")
    }
}

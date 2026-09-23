//
//  TeamOutlineTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import Testing
import Workspace

/// What the sidebar shows, checked without a view.
///
/// The snapshots come from a real store because `WorkerSnapshot` is made by
/// the store and stays that way; what is under test is the ordering and the
/// two texts, not the persistence, which `WorkerStoreTests` already covers.
@Suite("Team outline and row texts")
struct TeamOutlineTests {

    @Test("A manager comes before its reports, and depth follows the chain")
    func managersPrecedeReports() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let head  = try await store.createWorker(name: "Aaa", appearance: TemporaryStore.appearance())
        let lead  = try await store.createWorker(name: "Zzz", managerID: head.id,
                                                 appearance: TemporaryStore.appearance())
        let scout = try await store.createWorker(name: "Bbb", managerID: lead.id,
                                                 appearance: TemporaryStore.appearance())

        let rows = TeamOutline.rows(of: try await store.workers())

        #expect(rows.map(\.id) == [head.id, lead.id, scout.id])
        #expect(rows.map(\.depth) == [0, 1, 2])
        #expect(rows.map(\.hasReports) == [true, true, false])
    }

    @Test("A worker whose model is gone keeps its place and reads as to configure")
    func aMissingModelKeepsThePlace() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let head  = try await store.createWorker(name: "Aaa", role: "Lead", appearance: TemporaryStore.appearance())
        let gone  = try await store.createWorker(name: "Bbb", role: "Research", managerID: head.id,
                                                 appearance: TemporaryStore.appearance())
        try await store.configure(worker: head.id, selection: TemporaryStore.firstSelection)
        try await store.configure(worker: gone.id, selection: TemporaryStore.secondSelection)

        let workers = try await store.workers()
        let before  = TeamOutline.rows(of: workers)
        let after   = TeamOutline.rows(of: workers, modelUnavailable: [gone.id])

        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.depth) == after.map(\.depth))

        let row = try #require(after.first { $0.id == gone.id })
        #expect(row.worker.isConfigured)
        #expect(row.needsConfiguring)
        #expect(row.subtitle == TeamRow.toConfigure)
        #expect(row.accessibilityLabel.contains(TeamRow.toConfigure))
        #expect(after.first { $0.id == head.id }?.subtitle == "Lead")
    }

    @Test("Changing a worker's state does not move it in the list")
    func stateDoesNotReorder() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let head  = try await store.createWorker(name: "Aaa", appearance: TemporaryStore.appearance())
        let first = try await store.createWorker(name: "Bbb", managerID: head.id,
                                                 appearance: TemporaryStore.appearance())
        _ = try await store.createWorker(name: "Ccc", managerID: head.id,
                                         appearance: TemporaryStore.appearance())

        let before = TeamOutline.rows(of: try await store.workers())
        try await store.configure(worker: first.id, selection: TemporaryStore.firstSelection)
        let after = TeamOutline.rows(of: try await store.workers())

        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.depth) == after.map(\.depth))
        #expect(after.first { $0.id == first.id }?.worker.isConfigured == true)
    }

    @Test("A report whose manager is archived is listed, at the top level")
    func archivedManagerLeavesItsReportsVisible() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let head  = try await store.createWorker(name: "Aaa", appearance: TemporaryStore.appearance())
        let scout = try await store.createWorker(name: "Bbb", managerID: head.id,
                                                 appearance: TemporaryStore.appearance())
        try await store.update(worker: head.id, .archived(true))

        let rows = TeamOutline.rows(of: try await store.workers())

        #expect(rows.map(\.id) == [scout.id])
        #expect(rows.first?.depth == 0)
    }

    @Test("A collapsed manager hides its reports and keeps the rest of the team")
    func collapsedManagerHidesItsReports() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let head  = try await store.createWorker(name: "Aaa", appearance: TemporaryStore.appearance())
        _ = try await store.createWorker(name: "Bbb", managerID: head.id,
                                         appearance: TemporaryStore.appearance())
        let other = try await store.createWorker(name: "Ccc", appearance: TemporaryStore.appearance())

        let rows = TeamOutline.rows(of: try await store.workers(), collapsed: [head.id])

        #expect(rows.map(\.id) == [head.id, other.id])
        #expect(rows.first?.isCollapsed == true)
        #expect(rows.first?.hasReports == true)
    }

    @Test("The subtitle is the role, and says to configure while no model is attached")
    func subtitleChoosesRoleOrConfiguration() async throws {
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

        let attached = TeamOutline.rows(of: try await store.workers())
        #expect(attached.first { $0.id == roled.id }?.subtitle == "Research lead")
        #expect(attached.first { $0.id == roleless.id }?.subtitle == "")
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
}

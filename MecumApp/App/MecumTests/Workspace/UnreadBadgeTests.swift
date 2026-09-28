//
//  UnreadBadgeTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Testing
@testable import Mecum

/// The sidebar badge (§4.3), derived from a real store's read marker.
///
/// "On screen at its end" is the app's to know: `TeamModel` calls `markRead`
/// after each write to the open conversation while its reading position is
/// the end. These tests stand in for that by calling `markRead` the same way.
@Suite("Unread badge on the worker's row")
struct UnreadBadgeTests {

    private static let workspace = UUID()

    private struct Direct {
        let store       : WorkspaceStore
        let worker      : WorkerSnapshot
        let conversation: ConversationSnapshot

        init(in store: WorkspaceStore, name: String = "Atlas") async throws {
            self.store   = store
            worker       = try await store.createWorker(name: name, role: "Release engineer",
                                                        appearance: TemporaryStore.appearance())
            conversation = try await store.createConversation(kind: .direct, participants: [worker.id])
        }

        func reply(_ text: String = "done") async throws {
            try await store.appendMessage(to: conversation.id, author: worker.id, text: text, delivery: .completed)
        }

        func end(_ type: EventType) async throws {
            try await store.append(NewEvent(workspaceID: UnreadBadgeTests.workspace, subjectID: UUID(),
                                            conversationID: conversation.id, workerID: worker.id, type: type))
        }

        var state: UnreadState {
            get async throws { try await store.unreadByWorker()[worker.id] ?? .none }
        }
    }

    @Test("A reply arriving in a conversation not on screen counts")
    func aReplyOffScreenCounts() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let atlas = try await Direct(in: try WorkspaceStore.opening(in: directory))

        try await atlas.store.appendMessage(to: atlas.conversation.id, text: "check the build")
        try await atlas.reply("first")
        try await atlas.reply("second")

        #expect(try await atlas.state == UnreadState(replies: 2, hasUnseenProblem: false))
    }

    @Test("Opening the conversation and reaching its end clears the count")
    func readingToTheEndClears() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let atlas = try await Direct(in: try WorkspaceStore.opening(in: directory))
        try await atlas.reply()
        try await atlas.reply()

        try await atlas.store.markRead(conversation: atlas.conversation.id)

        #expect(try await atlas.state == .none)
        try await atlas.reply("after")
        #expect(try await atlas.state.replies == 1)
    }

    @Test("A reply arriving while the conversation is on screen at its end never counts")
    func aReplyOnScreenAtTheEndNeverCounts() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let atlas = try await Direct(in: try WorkspaceStore.opening(in: directory))
        try await atlas.store.markRead(conversation: atlas.conversation.id)

        for index in 1...3 {
            try await atlas.reply("block \(index)")
            try await atlas.store.markRead(conversation: atlas.conversation.id)
            #expect(try await atlas.store.unreadByWorker().isEmpty)
        }
        try await atlas.end(.executionCompleted)
        try await atlas.store.markRead(conversation: atlas.conversation.id)
        #expect(try await atlas.store.unreadByWorker().isEmpty)
    }

    @Test("Only the conversation's own worker is counted, never the person or another worker")
    func onlyTheWorkersOwnRepliesCount() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store = try WorkspaceStore.opening(in: directory)
        let atlas = try await Direct(in: store)
        let nova  = try await store.createWorker(name: "Nova", appearance: TemporaryStore.appearance())

        try await store.appendMessage(to: atlas.conversation.id, text: "from the person")
        try await store.appendMessage(to: atlas.conversation.id, author: nova.id, text: "from another worker")
        try await atlas.reply()

        // A conversation between workers lights no row, whoever wrote in it.
        let room = try await store.createConversation(kind: .room, participants: [atlas.worker.id, nova.id])
        try await store.appendMessage(to: room.id, author: nova.id, text: "between workers")
        try await store.appendMessage(to: room.id, author: atlas.worker.id, text: "between workers")

        let states = try await store.unreadByWorker()
        #expect(states[atlas.worker.id] == UnreadState(replies: 1, hasUnseenProblem: false))
        #expect(states[nova.id] == nil)
    }

    @Test("A failed or stopped turn not yet seen gives the attention mark and no number", arguments: [
        EventType.executionFailed, EventType.executionCancelled,
    ])
    func anUnseenProblemMarksWithoutANumber(_ ending: EventType) async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let atlas = try await Direct(in: try WorkspaceStore.opening(in: directory))
        try await atlas.reply("part of an answer")
        try await atlas.end(ending)

        let rows = TeamOutline.rows(of: [atlas.worker], unread: try await atlas.store.unreadByWorker())
        let row  = try #require(rows.first)
        #expect(row.needsAttention)
        #expect(row.badgeText == nil)
        #expect(row.accessibilityLabel.contains("Last response needs attention"))

        try await atlas.store.markRead(conversation: atlas.conversation.id)
        #expect(try await atlas.state == .none)
    }

    @Test("A completed turn gives no attention mark")
    func aCompletedTurnIsQuiet() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let atlas = try await Direct(in: try WorkspaceStore.opening(in: directory))
        try await atlas.end(.executionStarted)
        try await atlas.end(.toolActivity)
        try await atlas.end(.executionCompleted)

        #expect(try await atlas.store.unreadByWorker().isEmpty)
    }

    @Test("The count and the mark survive reopening the store")
    func theCountSurvivesReopening() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let atlas = try await Direct(in: try WorkspaceStore.opening(in: directory))
        try await atlas.reply()
        try await atlas.store.markRead(conversation: atlas.conversation.id)
        try await atlas.reply()
        try await atlas.reply()
        let nova = try await Direct(in: atlas.store, name: "Nova")
        try await nova.end(.executionFailed)

        let reopened = try WorkspaceStore.opening(in: directory)
        let states   = try await reopened.unreadByWorker()
        #expect(states[atlas.worker.id] == UnreadState(replies: 2, hasUnseenProblem: false))
        #expect(states[nova.worker.id] == UnreadState(replies: 0, hasUnseenProblem: true))
    }

    @Test("The badge caps at 99+ and the label reads the count")
    func theBadgeCapsAndReads() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let atlas = try await Direct(in: try WorkspaceStore.opening(in: directory))

        func row(_ replies: Int) -> TeamRow? {
            TeamOutline.rows(of: [atlas.worker],
                             unread: [atlas.worker.id: UnreadState(replies: replies, hasUnseenProblem: false)]).first
        }
        #expect(row(0)?.badgeText == nil)
        #expect(row(1)?.accessibilityLabel == "Atlas, Release engineer, Needs Setup, 1 unread reply")
        #expect(row(3)?.badgeText == "3")
        #expect(row(99)?.badgeText == "99")
        #expect(row(120)?.badgeText == "99+")
        #expect(row(120)?.accessibilityLabel.hasSuffix("120 unread replies") == true)
    }

    @Test("Rows never reorder when a badge appears or clears")
    func rowsNeverReorder() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store = try WorkspaceStore.opening(in: directory)
        let head  = try await Direct(in: store, name: "Aaa")
        let lead  = try await store.createWorker(name: "Zzz", appearance: TemporaryStore.appearance())
        let last  = try await Direct(in: store, name: "Bbb")
        try await store.createConversation(kind: .direct, participants: [lead.id])
        let workers = try await store.workers()
        let quiet   = TeamOutline.rows(of: workers)

        try await last.reply()
        try await last.reply()
        try await head.end(.executionFailed)
        let busy = TeamOutline.rows(of: workers, unread: try await store.unreadByWorker())

        #expect(busy.map(\.id) == quiet.map(\.id))
        #expect(busy.map(\.needsAttention) == quiet.map { $0.id == head.worker.id })
        #expect(busy.map(\.badgeText) == quiet.map { $0.id == last.worker.id ? "2" : nil })
    }
}

//
//  ConversationStoreTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Testing
@testable import Mecum

@Suite("Conversations, drafts and long histories")
struct ConversationStoreTests {

    @Test("A draft and a reading position survive a reopen")
    func draftAndPositionPersist() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store        = try WorkspaceStore.opening(in: directory)
        let worker       = try await store.createWorker(name: "Atlas",
                                                        appearance: TemporaryStore.appearance())
        let conversation = try await store.createConversation(participants: [worker.id])
        let anchor       = try await store.appendMessage(to: conversation.id, text: "First")
        try await store.appendMessage(to: conversation.id, text: "Second")

        try await store.update(conversation: conversation.id, .draft("half a sentence"))
        try await store.update(
            conversation: conversation.id,
            .readingPosition(anchorMessageID: anchor.id, offset: 37.5)
        )

        let reopened = try WorkspaceStore.opening(in: directory)
        let read     = try #require(try await reopened.conversation(conversation.id))

        #expect(read.draft == "half a sentence")
        #expect(read.readingAnchorMessageID == anchor.id)
        #expect(read.readingOffset == 37.5)
        #expect(read.participantIDs == [worker.id])
        #expect(read.kind == .direct)
    }

    @Test("Messages come back in the order they were written")
    func messagesKeepTheirOrder() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store        = try WorkspaceStore.opening(in: directory)
        let conversation = try await store.createConversation()

        // Timestamps run backwards on purpose: the order is the sequence the
        // store assigns, not the clock.
        for index in 1...20 {
            try await store.appendMessage(
                to  : conversation.id,
                text: "message \(index)",
                at  : Date(timeIntervalSince1970: Double(1000 - index))
            )
        }

        let reopened = try WorkspaceStore.opening(in: directory)
        let messages = try await reopened.messages(in: conversation.id)

        #expect(messages.count == 20)
        #expect(messages.map(\.sequence) == Array(1...20))
        #expect(messages.map(\.text) == (1...20).map { "message \($0)" })
    }

    @Test("A window around a position comes back without the whole history")
    func windowedRead() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store        = try WorkspaceStore.opening(in: directory)
        let conversation = try await store.createConversation()
        for index in 1...500 {
            try await store.appendMessage(to: conversation.id, text: "message \(index)")
        }

        let window = try await store.messages(in: conversation.id, around: 300, before: 5, after: 5)

        #expect(try await store.messageCount(in: conversation.id) == 500)
        #expect(window.count == 10)
        #expect(window.map(\.sequence) == Array(295...304))

        // A window at the start is short rather than padded.
        let head = try await store.messages(in: conversation.id, around: 1, before: 5, after: 3)
        #expect(head.map(\.sequence) == [1, 2, 3])
    }

    @Test("A message is saved locally before anything is sent")
    func deliveryStates() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store        = try WorkspaceStore.opening(in: directory)
        let conversation = try await store.createConversation()
        let message      = try await store.appendMessage(to: conversation.id, text: "Ciao")

        #expect(message.delivery == .savedLocally)
        #expect(message.isFromPerson)

        try await store.update(message: message.id, delivery: .sentToBackend)
        try await store.update(message: message.id, delivery: .interrupted)

        let reopened = try WorkspaceStore.opening(in: directory)
        let read     = try #require(try await reopened.messages(in: conversation.id).first)
        #expect(read.delivery == .interrupted)
    }
}

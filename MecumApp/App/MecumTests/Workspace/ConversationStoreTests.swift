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

    @Test("A reply's quote and the draft's quote survive a reopen, and the draft's clears")
    func quotesPersist() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store        = try WorkspaceStore.opening(in: directory)
        let worker       = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        )
        let conversation = try await store.createConversation(participants: [worker.id])
        let answer       = try await store.appendMessage(
            to    : conversation.id,
            author: worker.id,
            text  : "Two bundles failed.\nCapture and layout."
        )
        let quote        = MessageQuote(
            messageID     : answer.id,
            authorWorkerID: worker.id,
            text          : "Capture and layout."
        )
        let own          = MessageQuote(
            messageID     : UUID(),
            authorWorkerID: nil,
            text          : "My own words"
        )
        let reply        = try await store.appendMessage(
            to   : conversation.id,
            text : "Which first?",
            quote: quote
        )
        try await store.update(
            conversation: conversation.id,
            .draftQuote(own)
        )

        #expect(reply.quote == quote)
        let reopened = try WorkspaceStore.opening(in: directory)
        let messages = try await reopened.messages(in: conversation.id)
        #expect(messages.map(\.quote) == [nil, quote])
        #expect(messages.last?.text == "Which first?", "the quote is kept apart from the text")
        #expect(try await reopened.message(reply.id)?.quote == quote)
        let read = try #require(try await reopened.conversation(conversation.id))
        #expect(read.draftQuote == own)
        #expect(read.draftQuote?.isFromPerson == true)

        try await reopened.update(
            conversation: conversation.id,
            .draftQuote(nil)
        )
        #expect(try await reopened.conversation(conversation.id)?.draftQuote == nil)
    }

    @Test("A conversation's queue survives a reopen in order, each message with its quote, and empties")
    func queuePersists() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store        = try WorkspaceStore.opening(in: directory)
        let worker       = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        )
        let conversation = try await store.createConversation(participants: [worker.id])
        let other        = try await store.createConversation(participants: [UUID()])
        let quote        = MessageQuote(
            messageID     : UUID(),
            authorWorkerID: worker.id,
            text          : "Capture\nand layout."
        )
        let queue        = [
            QueuedMessage(text: "first"),
            QueuedMessage(
                text : "second, with a line\nbreak",
                quote: quote
            ),
            QueuedMessage(text: "third"),
        ]
        #expect(conversation.queue.isEmpty)

        let written = try await store.update(
            conversation: conversation.id,
            .queue(queue)
        )
        #expect(written.queue == queue)

        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.conversation(conversation.id)?.queue == queue)
        #expect(try await reopened.conversation(other.id)?.queue.isEmpty == true, "a queue is its conversation's")

        try await reopened.update(
            conversation: conversation.id,
            .queue(Array(queue.dropFirst()))
        )
        #expect(try await reopened.conversation(conversation.id)?.queue.map(\.text)
                == ["second, with a line\nbreak", "third"])
        try await reopened.update(
            conversation: conversation.id,
            .queue([])
        )
        #expect(try await WorkspaceStore.opening(in: directory).conversation(conversation.id)?.queue.isEmpty == true)
    }
}

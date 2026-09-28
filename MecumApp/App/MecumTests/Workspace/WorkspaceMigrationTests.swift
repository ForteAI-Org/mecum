//
//  WorkspaceMigrationTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import ModelTransports
import SwiftData
import Testing
@testable import Mecum

/// The real upgrades: stores written in the shapes the app stored before
/// replies (`StoreShapeV4`) and before the queue (`StoreShapeV5`), opened by
/// the app's one schema through `WorkspaceStore.opening(in:)`, with no
/// migration plan.
@Suite("Upgrading older stores")
struct WorkspaceMigrationTests {

    @Test("A store from before replies keeps every row, and reads no quote and an empty queue")
    func aStoreFromBeforeRepliesOpens() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let atlas          = UUID()
        let nova           = UUID()
        let conversationID = UUID()
        try writeStore(
            in: directory,
            as: StoreShapeV4.self
        ) { context in
            context.insert(Worker(
                id        : atlas,
                name      : "Atlas",
                role      : "Release engineer",
                appearance: TemporaryStore.appearance()
            ))
            context.insert(Worker(
                id        : nova,
                name      : "Nova",
                appearance: TemporaryStore.appearance(palette: "dawn")
            ))
            context.insert(WorkerConfiguration(
                workerID : atlas,
                version  : 1,
                selection: TemporaryStore.firstSelection
            ))
            context.insert(StoreShapeV4.Conversation(
                id            : conversationID,
                participantIDs: [atlas],
                draft         : "half a reply"
            ))
            context.insert(StoreShapeV4.Message(
                conversationID: conversationID,
                text          : "ask",
                sequence      : 1
            ))
            context.insert(StoreShapeV4.Message(
                conversationID: conversationID,
                authorWorkerID: atlas,
                text          : "answer",
                sequence      : 2
            ))
            context.insert(WorkspaceEvent(
                NewEvent(
                    workspaceID   : UUID(),
                    subjectID     : UUID(),
                    conversationID: conversationID,
                    workerID      : atlas,
                    type          : .executionFailed
                ),
                localOrder: 1
            ))
        }
        let file = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(WorkspaceStoreFile.isUpgradeDue(file))

        let upgraded = try WorkspaceStore.opening(in: directory)

        #expect(!WorkspaceStoreFile.isUpgradeDue(file))
        let backup = directory.appending(path: WorkspaceStoreFile.storeName + WorkspaceStoreFile.backupSuffix)
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))

        #expect(try await upgraded.workers().map(\.name) == ["Atlas", "Nova"])
        let worker = try #require(try await upgraded.worker(atlas))
        #expect(worker.role == "Release engineer")
        #expect(worker.appearance == TemporaryStore.appearance())
        #expect(worker.configuration == TemporaryStore.firstSelection)

        let conversation = try #require(try await upgraded.conversation(conversationID))
        #expect(conversation.draft == "half a reply")
        #expect(conversation.participantIDs == [atlas])
        #expect(conversation.resumableSession(for: .claudeCode) == "session-4")
        #expect(conversation.draftQuote == nil)
        #expect(conversation.queue.isEmpty)

        let messages = try await upgraded.messages(in: conversationID)
        #expect(messages.map(\.text) == ["ask", "answer"])
        #expect(messages.map(\.sequence) == [1, 2])
        #expect(messages.map(\.quote) == [nil, nil])
        #expect(messages.last?.authorWorkerID == atlas)
        #expect(try await upgraded.events(matching: EventQuery(scope: .conversation(conversationID))).count == 1)

        // The upgraded store takes the new columns, and keeps them across a reopen.
        let answer = try #require(messages.last)
        let quote  = MessageQuote(
            messageID     : answer.id,
            authorWorkerID: atlas,
            text          : "answer"
        )
        try await upgraded.update(
            conversation: conversationID,
            .draftQuote(quote)
        )
        try await upgraded.update(
            conversation: conversationID,
            .queue([QueuedMessage(text: "and then?")])
        )
        let reply = try await upgraded.appendMessage(
            to   : conversationID,
            text : "why?",
            quote: quote
        )
        #expect(reply.sequence == 3)

        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.conversation(conversationID)?.draftQuote == quote)
        #expect(try await reopened.conversation(conversationID)?.queue == [QueuedMessage(text: "and then?")])
        #expect(try await reopened.messages(in: conversationID).last?.quote == quote)
    }

    @Test("A store from the reply build keeps its quotes, and reads an empty queue")
    func aStoreFromTheReplyBuildOpens() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let atlas          = UUID()
        let conversationID = UUID()
        let answerID       = UUID()
        let quote          = MessageQuote(
            messageID     : answerID,
            authorWorkerID: atlas,
            text          : "Two bundles failed."
        )
        try writeStore(
            in: directory,
            as: StoreShapeV5.self
        ) { context in
            context.insert(Worker(
                id        : atlas,
                name      : "Atlas",
                appearance: TemporaryStore.appearance()
            ))
            context.insert(StoreShapeV5.Conversation(
                id            : conversationID,
                participantIDs: [atlas],
                draft         : "which one",
                draftQuote    : quote
            ))
            context.insert(StoreShapeV5.Message(
                conversationID: conversationID,
                text          : "ask",
                sequence      : 1
            ))
            context.insert(StoreShapeV5.Message(
                id            : answerID,
                conversationID: conversationID,
                authorWorkerID: atlas,
                text          : "Two bundles failed.",
                sequence      : 2
            ))
            context.insert(StoreShapeV5.Message(
                conversationID: conversationID,
                text          : "why?",
                sequence      : 3,
                quote         : quote
            ))
        }
        let file = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(WorkspaceStoreFile.isUpgradeDue(file))

        let upgraded = try WorkspaceStore.opening(in: directory)

        #expect(!WorkspaceStoreFile.isUpgradeDue(file))
        let conversation = try #require(try await upgraded.conversation(conversationID))
        #expect(conversation.draft == "which one")
        #expect(conversation.draftQuote == quote)
        #expect(conversation.queue.isEmpty)

        let messages = try await upgraded.messages(in: conversationID)
        #expect(messages.map(\.text) == ["ask", "Two bundles failed.", "why?"])
        #expect(messages.map(\.quote) == [nil, nil, quote])
        #expect(try await upgraded.worker(atlas)?.name == "Atlas")

        try await upgraded.update(
            conversation: conversationID,
            .queue([QueuedMessage(
                text : "and the other?",
                quote: quote
            )])
        )
        #expect(try await upgraded.conversation(conversationID)?.queue.first?.quote == quote)
    }
}

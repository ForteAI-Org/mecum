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

/// The real migrations: stores written by the v1, v2 and v3 schemas, opened by the
/// current one through `WorkspaceStore.opening(in:)`.
@Suite("Upgrading older stores")
struct WorkspaceMigrationTests {

    @Test("Workers, a draft and messages survive, and the provider session starts empty")
    func aV1StoreOpensIntactWithNoProviderSession() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let managerID      = UUID()
        let workerID       = UUID()
        let conversationID = UUID()
        let store  = directory.appending(path: WorkspaceStoreFile.storeName)
        let marker = directory.appending(path: WorkspaceStoreFile.versionMarkerName)

        // Written exactly as the v1 app wrote it: the v1 schema, and its marker.
        do {
            let schema    = Schema(versionedSchema: WorkspaceSchemaV1.self)
            let container = try ModelContainer(
                for           : schema,
                configurations: ModelConfiguration(schema: schema, url: store)
            )
            let context = ModelContext(container)
            context.insert(WorkspaceSchemaV1.Worker(id: managerID, name: "Atlas",
                                                    appearance: TemporaryStore.appearance()))
            context.insert(WorkspaceSchemaV1.Worker(id: workerID, name: "Nova", role: "Research",
                                                    managerID: managerID,
                                                    appearance: TemporaryStore.appearance(palette: "dawn")))
            context.insert(WorkerConfiguration(workerID: workerID, version: 1,
                                               selection: TemporaryStore.firstSelection))
            context.insert(WorkspaceSchemaV1.Conversation(id: conversationID, participantIDs: [workerID],
                                                          draft: "half a thought"))
            context.insert(Message(conversationID: conversationID, text: "first", sequence: 1))
            context.insert(Message(conversationID: conversationID, authorWorkerID: workerID,
                                   text: "second", sequence: 2, delivery: .completed))
            try context.save()
        }
        try "1.0.0".write(to: marker, atomically: true, encoding: .utf8)

        let upgraded = try WorkspaceStore.opening(in: directory)

        #expect(try String(contentsOf: marker, encoding: .utf8) == "4.0.0")
        #expect(WorkspaceStoreFile.currentVersionIdentifier() == "4.0.0")
        let backup = directory.appending(path: WorkspaceStoreFile.storeName + WorkspaceStoreFile.backupSuffix)
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))

        let nova = try #require(try await upgraded.worker(workerID))
        #expect(nova.name == "Nova")
        #expect(nova.role == "Research")
        #expect(nova.appearance == TemporaryStore.appearance(palette: "dawn"))
        #expect(nova.configuration == TemporaryStore.firstSelection)
        #expect(try await upgraded.worker(managerID)?.name == "Atlas")

        let conversation = try #require(try await upgraded.conversation(conversationID))
        #expect(conversation.draft == "half a thought")
        #expect(conversation.participantIDs == [workerID])
        #expect(conversation.providerSessionProvider == nil)
        #expect(conversation.providerSessionID == nil)
        for provider in ModelProvider.allCases {
            #expect(conversation.resumableSession(for: provider) == nil)
        }

        let messages = try await upgraded.messages(in: conversationID)
        #expect(messages.map(\.text) == ["first", "second"])
        #expect(messages.map(\.sequence) == [1, 2])
        #expect(messages.last?.authorWorkerID == workerID)
        #expect(messages.last?.delivery == .completed)

        // The upgraded store takes the new field and keeps its order.
        try await upgraded.update(conversation: conversationID,
                                  .providerSession(provider: .claudeCode, id: "session-1"))
        try await upgraded.appendMessage(to: conversationID, text: "third")
        #expect(try await upgraded.messages(in: conversationID).map(\.sequence) == [1, 2, 3])
        #expect(try await upgraded.conversation(conversationID)?.resumableSession(for: .claudeCode)
                == "session-1")
    }

    @Test("A v2 store's history reads as seen, and a reply after the upgrade counts")
    func aV2StoreStartsReadToTheEnd() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workerID       = UUID()
        let conversationID = UUID()
        let store  = directory.appending(path: WorkspaceStoreFile.storeName)
        let marker = directory.appending(path: WorkspaceStoreFile.versionMarkerName)

        // Written exactly as the v2 app wrote it: the v2 schema, and its marker.
        do {
            let schema    = Schema(versionedSchema: WorkspaceSchemaV2.self)
            let container = try ModelContainer(
                for           : schema,
                configurations: ModelConfiguration(schema: schema, url: store)
            )
            let context = ModelContext(container)
            context.insert(WorkspaceSchemaV1.Worker(id: workerID, name: "Atlas",
                                                    appearance: TemporaryStore.appearance()))
            context.insert(WorkspaceSchemaV2.Conversation(id: conversationID, participantIDs: [workerID]))
            context.insert(Message(conversationID: conversationID, text: "ask", sequence: 1))
            context.insert(Message(conversationID: conversationID, authorWorkerID: workerID,
                                   text: "answer", sequence: 2, delivery: .completed))
            context.insert(WorkspaceEvent(NewEvent(workspaceID: UUID(), subjectID: UUID(),
                                                   conversationID: conversationID, workerID: workerID,
                                                   type: .executionFailed), localOrder: 1))
            try context.save()
        }
        try "2.0.0".write(to: marker, atomically: true, encoding: .utf8)

        let upgraded = try WorkspaceStore.opening(in: directory)

        #expect(try String(contentsOf: marker, encoding: .utf8) == "4.0.0")
        #expect(try await upgraded.messages(in: conversationID).map(\.text) == ["ask", "answer"])
        #expect(try await upgraded.unreadByWorker().isEmpty)

        try await upgraded.appendMessage(to: conversationID, author: workerID, text: "later", delivery: .completed)
        #expect(try await upgraded.unreadByWorker()[workerID] == UnreadState(replies: 1, hasUnseenProblem: false))
    }

    @Test("A v3 worker that had a manager opens with its conversation and messages intact")
    func aV3StoreDropsTheManager() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let managerID      = UUID()
        let workerID       = UUID()
        let conversationID = UUID()
        let store  = directory.appending(path: WorkspaceStoreFile.storeName)
        let marker = directory.appending(path: WorkspaceStoreFile.versionMarkerName)

        // Written exactly as the v3 app wrote it: the v3 schema, and its marker.
        do {
            let schema    = Schema(versionedSchema: WorkspaceSchemaV3.self)
            let container = try ModelContainer(
                for           : schema,
                configurations: ModelConfiguration(schema: schema, url: store)
            )
            let context = ModelContext(container)
            context.insert(WorkspaceSchemaV1.Worker(id: managerID, name: "Iris",
                                                    appearance: TemporaryStore.appearance()))
            context.insert(WorkspaceSchemaV1.Worker(id: workerID, name: "Nova", role: "Editor",
                                                    managerID: managerID,
                                                    appearance: TemporaryStore.appearance(palette: "dawn")))
            context.insert(WorkerConfiguration(workerID: workerID, version: 1,
                                               selection: TemporaryStore.firstSelection))
            context.insert(Conversation(id: conversationID, participantIDs: [workerID]))
            context.insert(Message(conversationID: conversationID, text: "ask", sequence: 1))
            context.insert(Message(conversationID: conversationID, authorWorkerID: workerID,
                                   text: "answer", sequence: 2, delivery: .completed))
            try context.save()
        }
        try "3.0.0".write(to: marker, atomically: true, encoding: .utf8)

        let upgraded = try WorkspaceStore.opening(in: directory)

        #expect(try String(contentsOf: marker, encoding: .utf8) == "4.0.0")
        #expect(try await upgraded.workers().map(\.name) == ["Iris", "Nova"])

        let nova = try #require(try await upgraded.worker(workerID))
        #expect(nova.role == "Editor")
        #expect(nova.appearance == TemporaryStore.appearance(palette: "dawn"))
        #expect(nova.configuration == TemporaryStore.firstSelection)

        let conversation = try #require(try await upgraded.conversation(conversationID))
        #expect(conversation.participantIDs == [workerID])
        let messages = try await upgraded.messages(in: conversationID)
        #expect(messages.map(\.text) == ["ask", "answer"])
        #expect(messages.last?.authorWorkerID == workerID)
    }
}

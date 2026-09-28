//
//  WorkspaceStoreFileTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData
import Testing
@testable import Mecum

/// What §18.4 asks for around a migration: the copy taken before one runs, and
/// the previous store put back when it fails.
///
/// The upgrade is staged with a store written in an earlier shape, which is
/// what makes one due, and the failure by a container factory that damages the
/// store and throws, which is what a migration that dies halfway leaves
/// behind. The real upgrades are `WorkspaceMigrationTests`.
@Suite("Opening the store, and the copy a migration starts from")
struct WorkspaceStoreFileTests {

    @Test("A failed migration puts the previous store back")
    func failedMigrationRestoresTheBackup() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let workerID       = UUID()
        let conversationID = UUID()
        try writeStore(
            in: directory,
            as: StoreShapeV4.self
        ) { context in
            context.insert(Worker(
                id        : workerID,
                name      : "Atlas",
                appearance: TemporaryStore.appearance()
            ))
            context.insert(StoreShapeV4.Conversation(
                id            : conversationID,
                participantIDs: [workerID],
                draft         : ""
            ))
            context.insert(StoreShapeV4.Message(
                conversationID: conversationID,
                text          : "before the upgrade",
                sequence      : 1
            ))
        }

        struct MigrationDied: Error {}

        let failure = #expect(throws: WorkspaceStoreError.self) {
            try WorkspaceStoreFile.open(in: directory) { storeURL in
                // What a migration that dies halfway leaves: the store gone
                // and the error still to raise.
                for suffix in WorkspaceStoreFile.fileSuffixes {
                    let file = URL(fileURLWithPath: storeURL.path(percentEncoded: false) + suffix)
                    if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                        try FileManager.default.removeItem(at: file)
                    }
                }
                throw MigrationDied()
            }
        }

        guard case .migrationFailed(let underlying, let restoreFailure) = try #require(failure) else {
            Issue.record("expected a migration failure, got \(String(describing: failure))")
            return
        }
        #expect(underlying is MigrationDied)
        #expect(restoreFailure == nil)

        // What was put back is the earlier store, so the next launch upgrades it for real.
        let file = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(WorkspaceStoreFile.isUpgradeDue(file))
        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.worker(workerID)?.name == "Atlas")
        #expect(try await reopened.messages(in: conversationID).map(\.text) == ["before the upgrade"])
    }

    @Test("A launch on a store in the current shape copies nothing")
    func ordinaryLaunchTakesNoBackup() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let file = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(!WorkspaceStoreFile.isUpgradeDue(file), "no store is no upgrade")
        let store = try WorkspaceStore.opening(in: directory)
        try await store.createWorker(name: "Nova", appearance: TemporaryStore.appearance())
        #expect(!WorkspaceStoreFile.isUpgradeDue(file))

        _ = try WorkspaceStore.opening(in: directory)

        let backup = directory.appending(path: WorkspaceStoreFile.storeName + WorkspaceStoreFile.backupSuffix)
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) == false)
    }

    @Test("A store whose metadata cannot be read is copied before it is opened")
    func unreadableStoreCountsAsAnUpgrade() throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        try FileManager.default.createDirectory(
            at                         : directory,
            withIntermediateDirectories: true
        )
        let file = directory.appending(path: WorkspaceStoreFile.storeName)
        try Data("not a store".utf8).write(to: file)

        #expect(WorkspaceStoreFile.isUpgradeDue(file))
    }

    @Test("A failure with no upgrade due is reported as an open failure")
    func plainOpenFailure() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        struct Unopenable: Error {}

        let failure = #expect(throws: WorkspaceStoreError.self) {
            try WorkspaceStoreFile.open(in: directory) { _ in throw Unopenable() }
        }
        guard case .openFailed(let underlying) = try #require(failure) else {
            Issue.record("expected an open failure, got \(String(describing: failure))")
            return
        }
        #expect(underlying is Unopenable)
    }
}

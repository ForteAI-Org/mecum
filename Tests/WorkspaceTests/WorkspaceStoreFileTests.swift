//
//  WorkspaceStoreFileTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData
import Testing
@testable import Workspace

/// What §18.4 asks for around a migration: the copy taken before one runs, and
/// the previous store put back when it fails.
///
/// The upgrade is staged by writing an older version into the marker file,
/// the same signal a v1 store gives, and the failure by a container factory
/// that damages the store and throws, which is what a migration that dies
/// halfway leaves behind. The real v1 to v2 migration is `WorkspaceMigrationTests`.
@Suite("Opening the store, and the copy a migration starts from")
struct WorkspaceStoreFileTests {

    @Test("A failed migration puts the previous store back")
    func failedMigrationRestoresTheBackup() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Atlas",
                                                  appearance: TemporaryStore.appearance())
        let conversation = try await store.createConversation(participants: [worker.id])
        try await store.appendMessage(to: conversation.id, text: "before the upgrade")

        let marker = directory.appending(path: WorkspaceStoreFile.versionMarkerName)
        #expect(try String(contentsOf: marker, encoding: .utf8)
                == WorkspaceStoreFile.currentVersionIdentifier())
        try "0.9.0".write(to: marker, atomically: true, encoding: .utf8)

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

        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.worker(worker.id)?.name == "Atlas")
        #expect(try await reopened.messages(in: conversation.id).map(\.text) == ["before the upgrade"])
    }

    @Test("A launch on the current version copies nothing")
    func ordinaryLaunchTakesNoBackup() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        try await store.createWorker(name: "Nova", appearance: TemporaryStore.appearance())

        _ = try WorkspaceStore.opening(in: directory)

        let backup = directory.appending(path: WorkspaceStoreFile.storeName + WorkspaceStoreFile.backupSuffix)
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) == false)
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

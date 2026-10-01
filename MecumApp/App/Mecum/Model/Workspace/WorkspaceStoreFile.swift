//
//  WorkspaceStoreFile.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import CoreData
import Foundation
import SwiftData

/// WorkspaceStoreFile opens the store on disk and protects an upgrade with a
/// copy of what was there before.
///
/// The directory is always a parameter. This module never resolves a path of
/// its own: the app passes `~/Library/Application Support/Mecum`, beside the
/// `Runs`, `Perception`, `Knowledge` and `Conversations` directories the kit
/// and the command line already use, and a test passes a temporary one.
///
/// An upgrade is due when the store's own metadata does not match the current
/// models (`isUpgradeDue`), which is exactly when opening it migrates it, so no
/// version number has to be kept by hand. The store files are then copied
/// first, and a failure puts the copy back. Ordinary launches, where the store
/// matches, copy nothing.
///
/// `WorkspaceMigrationTests` opens real stores in earlier shapes through it,
/// and `WorkspaceStoreFileTests` stages the failure a real upgrade cannot be
/// made to produce on demand.
nonisolated enum WorkspaceStoreFile {

    static let storeName = "Workspace.store"

    /// The store file and the two SQLite companions it is only consistent
    /// with. A copy that took the first alone could restore a torn store.
    static let fileSuffixes = ["", "-wal", "-shm"]

    static let backupSuffix = ".backup"

    /// Opens the store in `directory`, creating the directory if needed.
    ///
    /// Throws `WorkspaceStoreError.migrationFailed` when an upgrade was due
    /// and the open failed, after putting the copy back; throws
    /// `WorkspaceStoreError.openFailed` otherwise. The caller owns the
    /// returned container.
    static func open(in directory: URL) throws -> ModelContainer {
        try open(in: directory, making: makeContainer(at:))
    }

    /// The seam the failed-upgrade test drives. `make` is what turns the store
    /// URL into a container, which in production is SwiftData opening and
    /// migrating it.
    static func open(
        in directory: URL,
        making make : (URL) throws -> ModelContainer
    ) throws -> ModelContainer {

        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let store     = directory.appending(path: storeName)
        let isUpgrade = isUpgradeDue(store)

        if isUpgrade { try backUp(store) }

        do {
            return try make(store)
        } catch {
            guard isUpgrade else { throw WorkspaceStoreError.openFailed(underlying: error) }
            // The open failure is what the caller needs; a failed restore is
            // reported beside it rather than in place of it.
            var restoreFailure: (any Error)?
            do { try restore(store) } catch { restoreFailure = error }
            throw WorkspaceStoreError.migrationFailed(underlying: error,
                                                      restoreFailure: restoreFailure)
        }
    }

    // MARK: Upgrade

    /// Whether the store at `store` was written in another shape than the
    /// current models, from the entity hashes in its metadata. No store is no
    /// upgrade. A store whose metadata cannot be read counts as one: it is
    /// copied before the open, which is the safe direction.
    static func isUpgradeDue(_ store: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: store.path(percentEncoded: false)) else { return false }

        guard let expected = currentModelHashes,
              let stored = try? modelHashes(at: store)
        else { return true }
        return expected != stored
    }

    /// SwiftData exposes no public conversion from its schema to NSManagedObjectModel.
    /// Read the public entity hashes from an empty scratch store once per process instead.
    /// Failure keeps upgrade detection conservative: the real store is backed up before opening.
    private static let currentModelHashes: [String: Data]? = {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "mecum-schema-\(UUID())",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: storeName)
            let container = try makeContainer(at: file)
            return try withExtendedLifetime(container) { try modelHashes(at: file) }
        } catch {
            return nil
        }
    }()

    private static func modelHashes(at store: URL) throws -> [String: Data]? {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: store
        )
        return metadata[NSStoreModelVersionHashesKey] as? [String: Data]
    }

    // MARK: Copy and restore

    static func backUp(_ store: URL) throws {
        let manager = FileManager.default
        for suffix in fileSuffixes {
            let from = URL(fileURLWithPath: store.path(percentEncoded: false) + suffix)
            let to   = URL(fileURLWithPath: from.path(percentEncoded: false) + backupSuffix)
            // A stale companion left from an older copy would restore a torn
            // store, so a missing source clears its backup rather than keeping it.
            try removeIfPresent(to)
            guard manager.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try manager.copyItem(at: from, to: to)
        }
    }

    static func restore(_ store: URL) throws {
        let manager = FileManager.default
        for suffix in fileSuffixes {
            let live   = URL(fileURLWithPath: store.path(percentEncoded: false) + suffix)
            let backup = URL(fileURLWithPath: live.path(percentEncoded: false) + backupSuffix)
            try removeIfPresent(live)
            guard manager.fileExists(atPath: backup.path(percentEncoded: false)) else { continue }
            try manager.copyItem(at: backup, to: live)
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Container

    /// SwiftData migrates an older store as it opens it, inferring the
    /// lightweight migration from the store's shape and the current one.
    private static func makeContainer(at store: URL) throws -> ModelContainer {
        let schema = Schema(WorkspaceSchema.models)
        return try ModelContainer(
            for           : schema,
            configurations: ModelConfiguration(
                schema: schema,
                url   : store
            )
        )
    }
}

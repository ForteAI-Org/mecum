//
//  WorkspaceStoreFile.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

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
/// A marker file next to the store records the schema version that last opened
/// it. When it disagrees with the current version, or is missing while a store
/// exists, an upgrade is due: the store files are copied first, and a failure
/// puts the copy back. Ordinary launches, where the versions agree, copy
/// nothing.
///
/// The current version is v4. `WorkspaceMigrationTests` opens real v1, v2 and v3 stores
/// through it, and `WorkspaceStoreFileTests` stages the failure a real upgrade
/// cannot be made to produce on demand.
public enum WorkspaceStoreFile {

    static let storeName         = "Workspace.store"
    static let versionMarkerName = "Workspace.schema-version"

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
    public static func open(in directory: URL) throws -> ModelContainer {
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
        let marker    = directory.appending(path: versionMarkerName)
        let version   = currentVersionIdentifier()
        let isUpgrade = manager.fileExists(atPath: store.path(percentEncoded: false))
                     && recordedVersion(at: marker) != version

        if isUpgrade { try backUp(store) }

        do {
            let container = try make(store)
            try version.write(to: marker, atomically: true, encoding: .utf8)
            return container
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

    // MARK: Version marker

    static func currentVersionIdentifier() -> String {
        let version = WorkspaceSchemaV4.versionIdentifier
        return "\(version.major).\(version.minor).\(version.patch)"
    }

    /// The version that last opened this store, or nil when there is no marker
    /// or it cannot be read. Absence is a result here, not a failure: both
    /// mean the store's version is unknown, and an unknown version is treated
    /// as an upgrade, which is the safe direction.
    private static func recordedVersion(at marker: URL) -> String? {
        try? String(contentsOf: marker, encoding: .utf8)
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

    private static func makeContainer(at store: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WorkspaceSchemaV4.self)
        return try ModelContainer(
            for           : schema,
            migrationPlan : WorkspaceMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: store)
        )
    }
}

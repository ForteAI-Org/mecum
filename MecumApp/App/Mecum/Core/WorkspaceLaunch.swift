//
//  WorkspaceLaunch.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Observation
import SQLiteLivingMemory

/// WorkspaceLaunch opens the workspace store when the app starts.
///
/// The app is where the path is decided, because the library takes its
/// directory as a parameter and resolves none of its own. This is the same
/// `~/Library/Application Support/Mecum` the seat broker keeps `Runs` and
/// `Perception` under, so the workspace database sits beside them.
///
/// Opening is attempted once. A failure is kept rather than thrown away: the
/// team sidebar in T3 has to say that the store did not open instead of
/// showing an empty team as if there were none.
@Observable
@MainActor
final class WorkspaceLaunch {

    private(set) var store: WorkspaceStore?
    /// One durable memory shared by workers, separate from their conversations.
    private(set) var livingMemory: SQLiteLivingMemoryStore?
    private(set) var memoryFailure: String?

    /// Why the store is not open, nil while it is or before the attempt.
    private(set) var failure: String?

    /// Where the store lives beside the kit's other directories.
    ///
    /// `MECUM_APP_SUPPORT_DIR` replaces it for one launch, so a second copy of
    /// the app can run without opening the store another process holds. A
    /// check run (`MecumApp.isCheckRun`) that names none gets a temporary one, so
    /// those runs never open the person's workspace. Worker workspaces and the
    /// Brain follow it.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["MECUM_APP_SUPPORT_DIR"], !override.isEmpty {
            return URL(
                filePath     : override,
                directoryHint: .isDirectory
            )
        }

        if MecumApp.isCheckRun {
            return URL.temporaryDirectory.appending(
                path         : "MecumCheckSupport",
                directoryHint: .isDirectory
            )
        }

        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in : .userDomainMask
        )[0]
        .appending(
            path         : "Mecum",
            directoryHint: .isDirectory
        )
    }

    /// Opens the store, or records why it could not be opened. Calling it
    /// again once the store is open does nothing.
    func open(in directory: URL = WorkspaceLaunch.directory) {
        guard store == nil else { return }

        do {
            store   = try WorkspaceStore.opening(in: directory)
            failure = nil
            do {
                livingMemory = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(
                    inKnowledgeDirectory: directory.appending(path: "Knowledge", directoryHint: .isDirectory)
                ))
                memoryFailure = nil
            } catch {
                livingMemory = nil
                memoryFailure = String(describing: error)
            }
        } catch {
            store   = nil
            failure = String(describing: error)
        }
    }
}

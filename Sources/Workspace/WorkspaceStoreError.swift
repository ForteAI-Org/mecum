//
//  WorkspaceStoreError.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// WorkspaceStoreError says what the store refused and whether anything
/// changed before it did.
public enum WorkspaceStoreError: Error {

    /// The store could not be opened and no upgrade was under way, so nothing
    /// was replaced.
    case openFailed(underlying: any Error)

    /// The store could not be opened while a schema upgrade was due. The copy
    /// taken beforehand was put back unless `restoreFailure` says why it was
    /// not. The original failure is kept either way.
    case migrationFailed(underlying: any Error, restoreFailure: (any Error)?)

    /// The move was refused before the save: making `workerID` report to
    /// `managerID` would have closed a loop in the hierarchy.
    case cycleInHierarchy(workerID: UUID, managerID: UUID)

    case workerNotFound(UUID)

    case conversationNotFound(UUID)

    case messageNotFound(UUID)

    /// No model is attached to the worker yet, so nothing can be run for it.
    case workerNotConfigured(UUID)
}

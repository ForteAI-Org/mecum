//
//  WorkspaceStore.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData

/// WorkspaceStore owns the workspace's persistent state.
///
/// SwiftData's `ModelContext` is not `Sendable` and neither is a `@Model`
/// class. The isolation that makes that safe is the actor itself: the context
/// and every model row stay inside it, and what crosses the boundary is a
/// snapshot value. Nothing here is marked unchecked; the compiler checks the
/// whole seam.
///
/// The actor, rather than the main actor, because a workspace holds tens of
/// thousands of events and ten thousand messages in one conversation, and
/// opening, migrating and querying that must not sit on the thread the
/// transcript scrolls on.
///
/// One instance per store directory per process. Orders (`Message.sequence`,
/// `WorkspaceEvent.localOrder`) are assigned by reading the current maximum
/// under this actor, which is exclusive within the process and not across
/// two processes opening the same directory.
@ModelActor
public actor WorkspaceStore {

    /// Opens the store in `directory` and returns the actor that owns it.
    ///
    /// The directory is the caller's decision: this module resolves no path of
    /// its own. Throws `WorkspaceStoreError`; see `WorkspaceStoreFile`.
    public static func opening(in directory: URL) throws -> WorkspaceStore {
        WorkspaceStore(modelContainer: try WorkspaceStoreFile.open(in: directory))
    }

    /// The single row matching `id`, or nil.
    func first<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

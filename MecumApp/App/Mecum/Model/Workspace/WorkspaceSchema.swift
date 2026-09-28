//
//  WorkspaceSchema.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData

/// WorkspaceSchema is the persisted shape of the workspace domain: the live
/// models, and one schema, with no frozen copies of earlier shapes.
///
/// It lists the models Increment 1 needs and nothing else. Task, Handoff,
/// Artifact, Memory, Room and Routing belong to increments 4 and 5; a schema
/// written before it is used is a schema to migrate for nothing.
///
/// An older store opens through the lightweight migration SwiftData infers on
/// its own, with no migration plan: every change so far adds an optional
/// column or one with a default, or drops a column, which that migration
/// handles. A change it cannot infer, such as a renamed or retyped column,
/// needs a plan again. `WorkspaceStoreFile` copies the store before an upgrade
/// and puts it back when one fails; `WorkspaceMigrationTests` opens stores as
/// the earlier shapes wrote them.
nonisolated enum WorkspaceSchema {

    static var models: [any PersistentModel.Type] {
        [
            Worker.self,
            WorkerConfiguration.self,
            Execution.self,
            Conversation.self,
            Message.self,
            WorkspaceEvent.self,
        ]
    }
}

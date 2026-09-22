//
//  WorkspaceSchema.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData

/// WorkspaceSchemaV1 is the first persisted shape of the workspace domain.
///
/// It lists the models Increment 1 needs and nothing else. Task, Handoff,
/// Artifact, Memory, Room and Routing belong to increments 4 and 5; a schema
/// written before it is used is a schema to migrate for nothing.
public enum WorkspaceSchemaV1: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
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

/// WorkspaceMigrationPlan carries the ordered schema versions the store opens
/// through.
///
/// There is exactly one version today, so `stages` is empty and no migration
/// runs. That is the honest state: a second version does not exist, and
/// inventing one to have something to migrate would test a fiction. What the
/// store does guarantee now is the protection around a migration, which
/// `WorkspaceStoreFile` implements and `WorkspaceStoreFileTests` covers. The
/// first real migration test arrives with v2.
public enum WorkspaceMigrationPlan: SchemaMigrationPlan {

    public static var schemas: [any VersionedSchema.Type] { [WorkspaceSchemaV1.self] }

    public static var stages: [MigrationStage] { [] }
}

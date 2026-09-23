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
///
/// `Conversation` is frozen here as it was in v1, so SwiftData can still read
/// a v1 store to migrate it. `Worker` is frozen here too, as v1 to v3 stored it,
/// and v2 and v3 share this copy. The other models are shared with later versions.
public enum WorkspaceSchemaV1: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            WorkspaceSchemaV1.Worker.self,
            WorkerConfiguration.self,
            Execution.self,
            WorkspaceSchemaV1.Conversation.self,
            Message.self,
            WorkspaceEvent.self,
        ]
    }

    /// Conversation as v1 stored it, before the provider session. Only the
    /// migration and its test use it; the app reads the current `Conversation`.
    @Model
    final class Conversation {

        #Unique<Conversation>([\.id])

        var id                    : UUID
        var kind                  : ConversationKind
        var title                 : String?
        var participantIDs        : [UUID]
        var draft                 : String
        var readingAnchorMessageID: UUID?
        var readingOffset         : Double
        var createdAt             : Date

        init(id: UUID, participantIDs: [UUID], draft: String, createdAt: Date = Date()) {
            self.id                     = id
            self.kind                   = .direct
            self.title                  = nil
            self.participantIDs         = participantIDs
            self.draft                  = draft
            self.readingAnchorMessageID = nil
            self.readingOffset          = 0
            self.createdAt              = createdAt
        }
    }

    /// Worker as v1 to v3 stored it, with the manager it reported to. Only the
    /// migration and its test use it; the app reads the current `Worker`.
    @Model
    final class Worker {

        #Unique<Worker>([\.id])
        #Index<Worker>([\.isArchived, \.name])

        var id          : UUID
        var name        : String
        var role        : String?
        var instructions: String?
        var managerID   : UUID?
        var isArchived  : Bool
        var createdAt   : Date
        var appearance  : WorkerAppearance

        init(
            id        : UUID,
            name      : String,
            role      : String? = nil,
            managerID : UUID?   = nil,
            appearance: WorkerAppearance
        ) {
            self.id           = id
            self.name         = name
            self.role         = role
            self.instructions = nil
            self.managerID    = managerID
            self.isArchived   = false
            self.createdAt    = Date()
            self.appearance   = appearance
        }
    }
}

/// WorkspaceMigrationPlan carries the ordered schema versions the store opens
/// through.
///
/// v1 to v2 adds the conversation's provider session as two optional
/// attributes, which SwiftData infers and fills with nil, so the stage is
/// lightweight. v2 to v3 adds the read marker with a default of zero, then
/// moves it to the end of every conversation: what was there before the
/// marker existed was read, and an upgrade must not light up the whole team.
/// v3 to v4 drops the worker's manager, a column SwiftData removes on its own,
/// so that stage is lightweight too.
/// `WorkspaceStoreFile` copies the store before any upgrade and puts it back
/// when one fails; `WorkspaceMigrationTests` runs the real ones.
public enum WorkspaceMigrationPlan: SchemaMigrationPlan {

    public static var schemas: [any VersionedSchema.Type] {
        [WorkspaceSchemaV1.self, WorkspaceSchemaV2.self, WorkspaceSchemaV3.self, WorkspaceSchemaV4.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: WorkspaceSchemaV1.self, toVersion: WorkspaceSchemaV2.self),
            .custom(
                fromVersion : WorkspaceSchemaV2.self,
                toVersion   : WorkspaceSchemaV3.self,
                willMigrate : nil,
                didMigrate  : { context in try WorkspaceStore.markEverythingRead(in: context) }
            ),
            .lightweight(fromVersion: WorkspaceSchemaV3.self, toVersion: WorkspaceSchemaV4.self),
        ]
    }
}

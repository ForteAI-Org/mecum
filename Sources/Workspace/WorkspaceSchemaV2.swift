//
//  WorkspaceSchemaV2.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import ModelTransports
import SwiftData

/// WorkspaceSchemaV2 is the second persisted shape of the workspace domain.
///
/// It differs from v1 only in `Conversation`, which now remembers the provider
/// session a worker's agent resumes, together with the provider it belongs to.
/// That `Conversation` is frozen here as v2 stored it, so a v2 store can still
/// be read to migrate it to v3.
public enum WorkspaceSchemaV2: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            WorkspaceSchemaV1.Worker.self,
            WorkerConfiguration.self,
            Execution.self,
            WorkspaceSchemaV2.Conversation.self,
            Message.self,
            WorkspaceEvent.self,
        ]
    }

    /// Conversation as v2 stored it, before the read marker. Only the
    /// migration and its test use it; the app reads the current `Conversation`.
    @Model
    final class Conversation {

        #Unique<Conversation>([\.id])

        var id                     : UUID
        var kind                   : ConversationKind
        var title                  : String?
        var participantIDs         : [UUID]
        var draft                  : String
        var readingAnchorMessageID : UUID?
        var readingOffset          : Double
        var createdAt              : Date
        var providerSessionProvider: ModelProvider?
        var providerSessionID      : String?

        init(id: UUID, participantIDs: [UUID], createdAt: Date = Date()) {
            self.id                      = id
            self.kind                    = .direct
            self.title                   = nil
            self.participantIDs          = participantIDs
            self.draft                   = ""
            self.readingAnchorMessageID  = nil
            self.readingOffset           = 0
            self.createdAt               = createdAt
            self.providerSessionProvider = nil
            self.providerSessionID       = nil
        }
    }
}

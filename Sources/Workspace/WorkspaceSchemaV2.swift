//
//  WorkspaceSchemaV2.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import SwiftData

/// WorkspaceSchemaV2 is the current persisted shape of the workspace domain.
///
/// It differs from v1 only in `Conversation`, which now remembers the provider
/// session a worker's agent resumes, together with the provider it belongs to.
public enum WorkspaceSchemaV2: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

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

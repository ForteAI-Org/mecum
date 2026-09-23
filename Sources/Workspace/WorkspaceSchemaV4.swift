//
//  WorkspaceSchemaV4.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import SwiftData

/// WorkspaceSchemaV4 is the current persisted shape of the workspace domain.
///
/// It differs from v3 only in `Worker`, which no longer reports to a manager:
/// the team is a flat list.
public enum WorkspaceSchemaV4: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

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

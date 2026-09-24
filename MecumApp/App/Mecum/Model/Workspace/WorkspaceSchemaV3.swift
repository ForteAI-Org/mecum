//
//  WorkspaceSchemaV3.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import SwiftData

/// WorkspaceSchemaV3 is the third persisted shape of the workspace domain.
///
/// It differs from v2 only in `Conversation`, which now remembers how far the
/// person has read it (`readUpToSequence`, `readUpToEventOrder`), so a row's
/// unread count is derived from the store and survives a relaunch. Its
/// `Worker` still has a manager, frozen in `WorkspaceSchemaV1`.
nonisolated enum WorkspaceSchemaV3: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WorkspaceSchemaV1.Worker.self,
            WorkerConfiguration.self,
            Execution.self,
            Conversation.self,
            Message.self,
            WorkspaceEvent.self,
        ]
    }
}

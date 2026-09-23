//
//  WorkspaceSchemaV3.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import SwiftData

/// WorkspaceSchemaV3 is the current persisted shape of the workspace domain.
///
/// It differs from v2 only in `Conversation`, which now remembers how far the
/// person has read it (`readUpToSequence`, `readUpToEventOrder`), so a row's
/// unread count is derived from the store and survives a relaunch.
public enum WorkspaceSchemaV3: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

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

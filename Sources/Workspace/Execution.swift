//
//  Execution.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import SwiftData

/// Execution is one attempt to run a turn, with the settings it actually ran
/// with.
///
/// `selection` and `configurationVersion` are copies taken when the attempt
/// starts, not a reference to the worker's current configuration. A profile
/// edited afterwards does not rewrite which model produced a result.
@Model
public final class Execution {

    #Unique<Execution>([\.id])
    #Index<Execution>([\.workerID, \.startedAt])

    public internal(set) var id: UUID

    public internal(set) var workerID: UUID

    public internal(set) var conversationID: UUID?

    public internal(set) var startedAt: Date

    /// The `WorkerConfiguration.version` this attempt was started from.
    public internal(set) var configurationVersion: Int

    /// The snapshot. Never rewritten after the attempt starts.
    public internal(set) var selection: ModelSelection

    public init(
        id                  : UUID  = UUID(),
        workerID            : UUID,
        conversationID      : UUID? = nil,
        startedAt           : Date  = Date(),
        configurationVersion: Int,
        selection           : ModelSelection
    ) {
        self.id                   = id
        self.workerID             = workerID
        self.conversationID       = conversationID
        self.startedAt            = startedAt
        self.configurationVersion = configurationVersion
        self.selection            = selection
    }
}

/// ExecutionSnapshot is an execution as it leaves the store.
public struct ExecutionSnapshot: Sendable, Hashable, Identifiable {

    public let id                  : UUID
    public let workerID            : UUID
    public let conversationID      : UUID?
    public let startedAt           : Date
    public let configurationVersion: Int
    public let selection           : ModelSelection

    init(_ execution: Execution) {
        self.id                   = execution.id
        self.workerID             = execution.workerID
        self.conversationID       = execution.conversationID
        self.startedAt            = execution.startedAt
        self.configurationVersion = execution.configurationVersion
        self.selection            = execution.selection
    }
}

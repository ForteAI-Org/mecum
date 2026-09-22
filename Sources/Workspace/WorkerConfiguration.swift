//
//  WorkerConfiguration.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import SwiftData

/// WorkerConfiguration is one version of what a worker runs with.
///
/// Versions are append-only: saving a change writes a new row rather than
/// editing the last one, because an `Execution` already finished must keep
/// saying which model produced its result. `version` starts at 1 and is
/// monotonic per worker, and the highest version is the current one.
///
/// A worker with no row here is to configure. There is no row meaning "no
/// model", so nothing can be mistaken for a default connection.
@Model
public final class WorkerConfiguration {

    #Unique<WorkerConfiguration>([\.workerID, \.version])

    public internal(set) var id: UUID

    public internal(set) var workerID: UUID

    /// 1 for the first saved configuration, then monotonic for that worker.
    public internal(set) var version: Int

    public internal(set) var createdAt: Date

    /// Provider, model and reasoning effort, in the vocabulary the transports
    /// already own, so the app has one authority for a provider name.
    public internal(set) var selection: ModelSelection

    public init(
        id       : UUID = UUID(),
        workerID : UUID,
        version  : Int,
        createdAt: Date = Date(),
        selection: ModelSelection
    ) {
        self.id        = id
        self.workerID  = workerID
        self.version   = version
        self.createdAt = createdAt
        self.selection = selection
    }
}

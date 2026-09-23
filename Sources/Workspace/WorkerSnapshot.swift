//
//  WorkerSnapshot.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports

/// WorkerSnapshot is a worker as it leaves the store.
///
/// `Worker` is a SwiftData model and is not `Sendable`: it belongs to the
/// context `WorkspaceStore` owns and must not cross that actor. This value
/// does cross, and it is a copy, not a live view: a later edit does not show
/// up in a snapshot already handed out.
public struct WorkerSnapshot: Sendable, Hashable, Identifiable {

    public let id          : UUID
    public let name        : String
    public let role        : String?
    public let instructions: String?
    public let isArchived  : Bool
    public let createdAt   : Date
    public let appearance  : WorkerAppearance

    /// The current configuration version, or nil while the worker has none.
    public let configurationVersion: Int?

    /// What the worker would run with now, or nil while it is to configure.
    public let configuration: ModelSelection?

    /// False while no model is attached. Such a worker is saved and listed;
    /// it cannot answer, and nothing pretends it can.
    public var isConfigured: Bool { configuration != nil }

    init(_ worker: Worker, configuration: WorkerConfiguration?) {
        self.id                   = worker.id
        self.name                 = worker.name
        self.role                 = worker.role
        self.instructions         = worker.instructions
        self.isArchived           = worker.isArchived
        self.createdAt            = worker.createdAt
        self.appearance           = worker.appearance
        self.configurationVersion = configuration?.version
        self.configuration        = configuration?.selection
    }
}

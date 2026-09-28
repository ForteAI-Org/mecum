//
//  Worker.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData

/// Worker is the persistent identity the person creates and keeps.
///
/// The row holds identity. Which model answers for
/// it lives in `WorkerConfiguration`, versioned, and the absence of any
/// configuration row is what "to configure" means: no default connection is
/// invented here.
///
/// There is deliberately no stored status. Visible state comes from three
/// separate dimensions (availability, current activity, attention wanted) and
/// is derived when it is shown; one stored enum would confuse having no work
/// with having no credentials.
///
/// Mutation goes through `WorkspaceStore`.
@Model
nonisolated final class Worker {

    #Unique<Worker>([\.id])
    #Index<Worker>([\.isArchived, \.name])

    /// Stable across renames, model changes and appearance regeneration.
    var id: UUID

    var name: String

    /// The short role the team list and the routing read. May be empty.
    var role: String?

    /// The longer description of responsibilities and preferences. May be
    /// empty: a worker without one is a generalist, and nothing infers a
    /// specialisation from its name.
    var instructions: String?

    /// Archiving is the ordinary removal from the active team. Deleting for
    /// good is a separate act, `WorkspaceStore.deleteWorker`.
    var isArchived: Bool

    var createdAt: Date

    /// The mascot descriptor. Only an explicit regenerate replaces it.
    var appearance: WorkerAppearance

    init(
        id          : UUID    = UUID(),
        name        : String,
        role        : String? = nil,
        instructions: String? = nil,
        isArchived  : Bool    = false,
        createdAt   : Date    = Date(),
        appearance  : WorkerAppearance
    ) {
        self.id           = id
        self.name         = name
        self.role         = role
        self.instructions = instructions
        self.isArchived   = isArchived
        self.createdAt    = createdAt
        self.appearance   = appearance
    }
}

/// WorkerChange names one edit to a worker.
///
/// One case per field, so "leave unchanged" and "set to nothing" stay
/// distinguishable, which a bag of optional parameters cannot do.
nonisolated enum WorkerChange: Sendable, Equatable {
    case name(String)
    case role(String?)
    case instructions(String?)
    case appearance(WorkerAppearance)
    case archived(Bool)
}

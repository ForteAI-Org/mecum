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
/// The row holds identity and place in the hierarchy. Which model answers for
/// it lives in `WorkerConfiguration`, versioned, and the absence of any
/// configuration row is what "to configure" means: no default connection is
/// invented here.
///
/// There is deliberately no stored status. Visible state comes from three
/// separate dimensions (availability, current activity, attention wanted) and
/// is derived when it is shown; one stored enum would confuse having no work
/// with having no credentials.
///
/// Mutation goes through `WorkspaceStore`, which is what holds the invariants
/// this class cannot: `managerID` is refused before the save when it would
/// close a cycle.
@Model
public final class Worker {

    #Unique<Worker>([\.id])
    #Index<Worker>([\.isArchived, \.name])

    /// Stable across renames, model changes and appearance regeneration.
    public internal(set) var id: UUID

    public var name: String

    /// The short role the team list and the routing read. May be empty.
    public var role: String?

    /// The longer description of responsibilities and preferences. May be
    /// empty: a worker without one is a generalist, and nothing infers a
    /// specialisation from its name.
    public var instructions: String?

    /// Zero or one manager, several workers at the root. Written only by
    /// `WorkspaceStore`, which refuses a cycle before it saves.
    public internal(set) var managerID: UUID?

    /// Archiving is the ordinary removal from the active team. Hard deletion
    /// is a separate act and is not implemented here.
    public var isArchived: Bool

    public internal(set) var createdAt: Date

    /// The mascot descriptor. Only an explicit regenerate replaces it.
    public var appearance: WorkerAppearance

    public init(
        id          : UUID    = UUID(),
        name        : String,
        role        : String? = nil,
        instructions: String? = nil,
        managerID   : UUID?   = nil,
        isArchived  : Bool    = false,
        createdAt   : Date    = Date(),
        appearance  : WorkerAppearance
    ) {
        self.id           = id
        self.name         = name
        self.role         = role
        self.instructions = instructions
        self.managerID    = managerID
        self.isArchived   = isArchived
        self.createdAt    = createdAt
        self.appearance   = appearance
    }
}

/// WorkerChange names one edit to a worker.
///
/// One case per field, so "leave unchanged" and "set to nothing" stay
/// distinguishable, which a bag of optional parameters cannot do.
public enum WorkerChange: Sendable, Equatable {
    case name(String)
    case role(String?)
    case instructions(String?)
    case appearance(WorkerAppearance)
    case archived(Bool)
    case manager(UUID?)
}

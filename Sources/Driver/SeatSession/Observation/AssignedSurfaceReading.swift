//
//  AssignedSurfaceReading.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import SeatCore

/// SelectionClaimBatch is every selection fact one reading supports, gathered so
/// the seat folds them in one pass instead of asking five questions.
///
/// It carries claims and no conclusions: each claim is refused by the nucleus
/// unless its provenance can carry the conclusion it is about. An empty batch is
/// the honest answer of an adapter that has no qualified evidence, and it leaves
/// the surfaces ineligible with `roleNotRead` and `visibilityNotRead` rather than
/// assuming they are documents that are visible.
nonisolated package struct SelectionClaimBatch: Sendable, Equatable {

    package var roles       : [SurfaceRoleClaim]       = []
    package var parents     : [SurfaceParentClaim]     = []
    package var modals      : [ModalRelationClaim]     = []
    package var visibilities: [SurfaceVisibilityClaim] = []
    package var recency     : [RecencyClaim]           = []

    package static let none = SelectionClaimBatch()

    package init(
        roles       : [SurfaceRoleClaim]       = [],
        parents     : [SurfaceParentClaim]     = [],
        modals      : [ModalRelationClaim]     = [],
        visibilities: [SurfaceVisibilityClaim] = [],
        recency     : [RecencyClaim]           = []
    ) {
        self.roles        = roles
        self.parents      = parents
        self.modals       = modals
        self.visibilities = visibilities
        self.recency      = recency
    }
}

/// AssignedSurfaceReading supplies the seat with one pass over the surfaces that
/// may belong to the assigned instance, and with whatever selection facts
/// qualified evidence supports about them.
///
/// ## Why the seat does not read this itself
///
/// The two questions have different evidence. Which window a row is about comes
/// from the window server connection and is attested. Whether the reading is the
/// **whole** of the instance's surfaces, and what each surface is, come from
/// adapters that have to be qualified separately, and none of them exists on
/// this build. Making the reading a role keeps that gap visible: the shipped
/// conformer reports an incomplete enumeration and no selection claims, the
/// causes of the gate name it, and a controlled conformer in a suite exercises
/// the algorithms without either of them certifying the system.
///
/// A conformer is borrowed by the seat, holds no seat state, and is called on
/// the main actor at the points the seat already takes readings.
nonisolated package protocol AssignedSurfaceReading: Sendable {

    /// One pass over the surfaces of the given processes. A failed pass answers
    /// `SurfaceInventoryReading.unavailable`, which leaves membership untouched
    /// and is never an application with no windows.
    func read(ownedBy processIDs: Set<Int32>) -> SurfaceInventoryReading

    /// The selection facts this adapter can attest for the rows of `reading`.
    func selectionClaims(for reading: SurfaceInventoryReading) -> SelectionClaimBatch
}

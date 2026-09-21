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

/// One atomic pass over membership and selection evidence.
///
/// Keeping the two together matters for the native adapter: the AX role and
/// visibility claims must describe the exact WindowServer identities carried by
/// the inventory, not a second reading taken after a window changed.
nonisolated package struct AssignedSurfaceSnapshot: Sendable, Equatable {

    package let inventory: SurfaceInventoryReading
    package let claims   : SelectionClaimBatch

    /// Surfaces the assigned application no longer lists among its windows
    /// while the window server still holds a visible surface for them.
    ///
    /// The cross-check reports every one it saw. The transition filter then
    /// narrows the set to those that have stayed that way long enough to
    /// exclude a slow accessibility reading, and that narrowed set is the one a
    /// seat may confirm a closure on. Empty from an adapter that cannot attest
    /// which windows an application scopes.
    package let withdrawnByApplication: [WindowIdentity]

    package init(
        inventory: SurfaceInventoryReading,
        claims   : SelectionClaimBatch = .none,
        withdrawnByApplication: [WindowIdentity] = []
    ) {
        self.inventory = inventory
        self.claims    = claims
        self.withdrawnByApplication = withdrawnByApplication
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
/// adapters that have to be qualified separately. The shipped conformer now
/// cross-checks AX and WindowServer and emits role, modal and visibility claims
/// only for identities present in both readings. Making the reading a role keeps
/// every mismatch visible and lets a controlled conformer exercise the same
/// algorithms without TCC.
///
/// A conformer is borrowed by the seat, holds no seat state, and is called on
/// the main actor at the points the seat already takes readings.
nonisolated package protocol AssignedSurfaceReading: Sendable {

    /// One pass over the surfaces of the given processes and the selection
    /// facts read in that same pass. A failed inventory answers
    /// `SurfaceInventoryReading.unavailable`, which leaves membership untouched
    /// and is never an application with no windows.
    func snapshot(ownedBy processIDs: Set<Int32>) -> AssignedSurfaceSnapshot
}

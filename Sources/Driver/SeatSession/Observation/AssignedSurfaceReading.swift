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

/// RetainedSurfaceDisposition is what one pass established about a surface it
/// looked the window server up for by identity and did not find in the
/// application's own accessibility window scope.
///
/// The five answers are kept apart because only two of them say the surface is
/// gone. Merging them is how a modal stack loses the window underneath its top
/// level: the absence of a parent from `AXWindows` while a child dialog is open
/// is not the parent going away, and a time grace alone establishes nothing.
nonisolated package enum RetainedSurfaceDisposition: Sendable, Equatable {

    /// Named in this pass's own window server request and answered with no row
    /// at all. It is the one absence that proves the window ended.
    case destroyed

    /// On screen, outside the application's scope, and no surface in that scope
    /// attests it as an ancestor. It is the application's own statement, and
    /// the transition filter is what decides it has stood long enough.
    case withdrawn

    /// On screen and positively attested by a surface that **is** in the scope
    /// as that surface's parent window. It is the nested dialog case: the top
    /// accessibility level shows the child alone while the parent is still
    /// there, blocked and drawn under it. The ancestor is kept as a member.
    case obscuredByChild(WindowIdentity)

    /// On screen and outside the scope, inside the short deadline that tells a
    /// withdrawal from an accessibility reading that has not caught up. Nothing
    /// is concluded from it and the surface keeps being looked up.
    case temporarilyUnreadable

    /// The window server answered for that Window ID with a different window.
    /// The surface being looked up is not the one on screen, so this pass says
    /// nothing about it and stops carrying it.
    case unrelated
}

/// One atomic pass over membership and selection evidence.
///
/// Keeping the two together matters for the native adapter: the AX role and
/// visibility claims must describe the exact WindowServer identities carried by
/// the inventory, not a second reading taken after a window changed.
nonisolated package struct AssignedSurfaceSnapshot: Sendable, Equatable {

    package let inventory: SurfaceInventoryReading
    package let claims   : SelectionClaimBatch

    /// What this pass established about each surface it looked up by identity
    /// and did not find in the application's own window scope. A surface the
    /// pass found is not in it at all: it is a row like any other.
    ///
    /// The cross-check reports what it could see in one pass. The transition
    /// filter then holds a withdrawal inside its grace as
    /// `temporarilyUnreadable`, and only the narrowed set a seat may confirm a
    /// closure on reaches `withdrawnByApplication`.
    package let retained: [WindowIdentity: RetainedSurfaceDisposition]

    /// Surfaces the assigned application no longer lists among its windows
    /// while the window server still holds a visible surface for them, and
    /// which no surface in the scope attests as an ancestor.
    ///
    /// Empty from an adapter that cannot attest which windows an application
    /// scopes.
    package var withdrawnByApplication: [WindowIdentity] { identities(.withdrawn) }

    /// Surfaces the window server was asked for by identity and answered no row
    /// for at all, so they are destroyed and no wait brings them back.
    ///
    /// It is the one positive proof of closure this reading can make, and it is
    /// separate from every absence: the pass named these Window IDs in its own
    /// request, and a window server that answers nothing for a named id is not
    /// a reading that missed something. A pass that could not read the window
    /// server reports none, because it asked nothing.
    package var destroyedByWindowServer: [WindowIdentity] { identities(.destroyed) }

    package init(
        inventory: SurfaceInventoryReading,
        claims   : SelectionClaimBatch = .none,
        retained : [WindowIdentity: RetainedSurfaceDisposition] = [:]
    ) {
        self.inventory = inventory
        self.claims    = claims
        self.retained  = retained
    }

    private func identities(_ disposition: RetainedSurfaceDisposition) -> [WindowIdentity] {
        retained
            .filter { $0.value == disposition }
            .keys
            .sorted { $0.windowNumber < $1.windowNumber }
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

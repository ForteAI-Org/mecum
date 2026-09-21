//
//  SurfaceRole.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// SurfaceRole is what a surface of an assigned application is, as far as being
/// a target goes. Membership does not imply eligibility, and this is where the
/// difference is decided.
///
/// The three eligible roles are the ones a person works in. A tooltip and a
/// decoration are surfaces of the same application that nobody operates, and a
/// contextual menu is a transient of the window it was opened from: it is
/// observable and usable while it is up, and it is not an ordinary window in the
/// history of targets.
nonisolated package enum SurfaceRole: String, Sendable, Equatable, CaseIterable {

    case document
    case dialog
    case interactivePanel
    case tooltip
    case decoration

    /// The menu a right click opens inside the target: transient of its parent,
    /// never a target of its own in the recency of the application.
    case contextualMenu

    /// True for the three roles that may become the Selected Target.
    package var mayBeSelected: Bool {
        switch self {
            case .document, .dialog, .interactivePanel:       true
            case .tooltip, .decoration, .contextualMenu:      false
        }
    }

    /// True for the transient that belongs to a parent window instead of
    /// standing beside it.
    package var isTransientMenu: Bool { self == .contextualMenu }
}

/// SurfaceRoleClaim is a statement about what one attested surface is, together
/// with where that statement came from.
///
/// A claim is not a role. The nucleus records it only when its provenance can
/// carry `SelectionConclusion.surfaceRole`, which is the difference between a
/// role that was read and a role that was guessed from a window level.
nonisolated package struct SurfaceRoleClaim: Sendable, Equatable {

    package let surface   : WindowIdentity
    package let role      : SurfaceRole
    package let provenance: SelectionProvenance

    package init(surface: WindowIdentity, role: SurfaceRole, provenance: SelectionProvenance) {
        self.surface    = surface
        self.role       = role
        self.provenance = provenance
    }
}

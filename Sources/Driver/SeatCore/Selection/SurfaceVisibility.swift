//
//  SurfaceVisibility.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// SurfaceVisibility is what an established reading says about whether a member
/// surface can be worked in right now.
///
/// Hiding, minimising and withdrawing are their own cases because they are not
/// closing: the surface stays a member, its reference stays valid, and only its
/// eligibility as a target goes away. `uncertain` is the fifth case and the important one:
/// a reading that could not decide suspends the input and, deliberately, does
/// not take eligibility away, because losing eligibility would replace the
/// current target on the strength of something nobody read.
///
/// An absence from a reading is **not** in this enum. It is the inventory's
/// `SurfacePresence.absentUncertain` and it establishes none of these states.
nonisolated package enum SurfaceVisibility: String, Sendable, Equatable {

    /// Established visible and interactive, which is the state a qualified
    /// appearance, reappearance or return to the front reports.
    case visibleInteractive

    /// Established hidden. Membership persists, eligibility does not.
    case hiddenEstablished

    /// Established minimised. Membership persists, eligibility does not.
    case minimisedEstablished

    /// AX no longer enumerates a previously qualified surface while
    /// WindowServer still attests the same off-screen identity. Membership and
    /// modal history persist, but a withdrawn modal no longer blocks its parent.
    case withdrawnEstablished

    /// The reading did not decide. Input is suspended, nothing is closed and
    /// nothing is replaced.
    case uncertain
}

/// SurfaceVisibilityClaim is one reading of a surface's visibility, with where
/// it came from.
///
/// The provenance must carry `SelectionConclusion.visibilityState`. An on-screen
/// window list cannot: a hidden window is simply missing from it, so reading a
/// hiding out of it would be reading an absence.
nonisolated package struct SurfaceVisibilityClaim: Sendable, Equatable {

    package let surface   : WindowIdentity
    package let state     : SurfaceVisibility
    package let provenance: SelectionProvenance

    package init(surface: WindowIdentity, state: SurfaceVisibility, provenance: SelectionProvenance) {
        self.surface    = surface
        self.state      = state
        self.provenance = provenance
    }
}

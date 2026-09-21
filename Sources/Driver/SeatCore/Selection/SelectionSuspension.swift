//
//  SelectionSuspension.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// EligibilityRefusal is why a member surface cannot be a target. It is about
/// eligibility only: the surface stays a member of the assignment, keeps its
/// reference and is contained like the rest.
nonisolated package enum EligibilityRefusal: Sendable, Equatable {

    /// It is not a member of the assignment.
    case notAMember

    /// No qualified reading has said what this surface is. A surface whose role
    /// nobody established is not made a target on the assumption that it is a
    /// document.
    case roleNotRead

    /// A tooltip or a decoration.
    case roleCannotBeSelected(SurfaceRole)

    /// A contextual menu, which belongs to the parent it was opened from and
    /// does not enter the history of targets. The parent is carried when one was
    /// attested.
    case transientMenu(of: WindowIdentity?)

    /// No qualified reading has said whether the surface is visible.
    case visibilityNotRead

    /// Established hidden. Membership persists.
    case hiddenEstablished

    /// Established minimised. Membership persists.
    case minimisedEstablished
}

/// SelectionSuspension is one reason the agent may not act on the target right
/// now. The causes are independent and reported together: resolving one of them
/// says nothing about the others, and a successful containment does not reopen
/// the gate on its own.
nonisolated package enum SelectionSuspension: Sendable, Equatable {

    /// No application is assigned, so there is nothing to select in.
    case notAssigned

    /// No member surface is eligible and unblocked. The assignment stands and
    /// the input stays suspended: zero eligible targets is not the end of an
    /// assignment.
    case noEligibleTarget

    /// Several surfaces are equally plausible and their order was not observed,
    /// so the consumer is asked to choose rather than being handed an invented
    /// recency. The candidates are listed in Window ID order, which is a stable
    /// presentation and not a ranking.
    case explicitSelectionRequired(candidates: [WindowIdentity])

    /// A modal block is why a surface is not available. Reported when nothing is
    /// selectable, so that "no eligible target" is not the whole answer.
    case modalBlock(modal: WindowIdentity, blocked: WindowIdentity)

    /// A modal relation could not be established. It suspends the input and
    /// grants no bypass.
    case modalRelationInDoubt(ModalDoubt)

    /// A visibility reading did not decide. Nothing is closed and nothing is
    /// replaced; the input waits.
    case visibilityUncertain(WindowIdentity)

    /// The selected surface was not in the last reading. An absence proves
    /// neither a closure nor a hiding, so the target is kept and the input
    /// waits.
    case selectedSurfaceAbsent(WindowIdentity)

    /// The selected surface has one sighting and no second agreeing reading, so
    /// its identity and geometry are not established for this moment.
    case selectedSurfaceNotVerified(WindowIdentity)

    /// The assignment's own containment is not verified. The blocks are carried
    /// through unchanged, and the list is empty when no reading has been folded
    /// in yet.
    case containmentNotVerified(blocks: [ContainmentBlock])

    /// No observation of the selected target was offered.
    case observationMissing

    /// The observation was taken under an earlier selection. A change of target
    /// invalidates it at once, and coming back to the same window later is a new
    /// selection rather than a revival of the old one.
    case observationSuperseded(observed: UInt64, current: UInt64)

    /// The observation is of another window.
    case observationIdentityMismatch(observed: WindowIdentity, selected: WindowIdentity)

    /// The window's frame is no longer the one the observation was taken at, so
    /// the image is not of where the window is now.
    case observationGeometryStale(WindowIdentity)
}

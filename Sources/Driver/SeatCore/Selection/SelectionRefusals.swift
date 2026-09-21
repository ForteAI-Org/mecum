//
//  SelectionRefusals.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// SelectionClaimRefusal is why a fact offered to the selection nucleus was not
/// recorded. Every case is a rejection before any state changed, with the thing
/// that was wrong named, so a consumer can correct the claim instead of reading
/// "claim rejected".
nonisolated package enum SelectionClaimRefusal: Sendable, Equatable, Error {

    /// The evidence cannot carry this conclusion. It may be perfectly good
    /// evidence of something else.
    case provenanceCannotCarry(conclusion: SelectionConclusion, provenance: SelectionProvenance)

    /// The event is not one of the three that move the recency. Attribution, a
    /// geometry that agreed, a return from an uncertain absence, a change of the
    /// global focus and a placement the kit asked for are all real events, and
    /// none of them is an appearance, a reappearance or a return to the front.
    case signalIsNotRecency(RecencySignal)

    /// The surface came forward for a reason that is not the application's, or
    /// for a reason nobody could attribute. The kit's own raises during
    /// containment and preparation are in here, and so is "we cannot tell".
    case raiseIsNotFromApplication(RecencyClaim.Origin)

    /// The surface is not a member of the assignment. The seat has no recency of
    /// windows it was not given.
    case surfaceIsNotAMember(WindowIdentity)

    /// A contextual menu is a transient of its parent and does not enter the
    /// history of targets.
    case transientMenuHasNoRecency(WindowIdentity)

    /// The claim names the surface as its own parent or its own modal.
    case relationIsSelfReferential(WindowIdentity)

    /// Recording the relation would close a loop with the ones already recorded.
    case relationIsCyclic(WindowIdentity)

    /// A qualified claim disagrees with the scope already recorded for this
    /// surface. The recorded scope stands and the contradiction is reported as a
    /// doubt: a later claim does not silently unblock a modal.
    case relationContradictsRecordedScope(WindowIdentity)

    /// The event is older than what is already known about this surface. A late
    /// result updates nothing and does not move the target.
    case recencyIsNotNewer(WindowIdentity)
}

/// ExplicitSelectionRefusal is why the consumer's own choice of target was not
/// taken. The explicit choice is a policy alternative to the automatic recency
/// and never a way around the conditions.
nonisolated package enum ExplicitSelectionRefusal: Sendable, Equatable, Error {

    case notAssigned

    case surfaceIsNotAMember(WindowIdentity)

    /// The surface is a member and cannot be a target: its role, or an
    /// established hiding or minimising.
    case surfaceIsNotEligible(EligibilityRefusal)

    /// A modal block covers the surface. Choosing it explicitly would be
    /// choosing to ignore the block.
    case modallyBlocked(by: WindowIdentity)
}

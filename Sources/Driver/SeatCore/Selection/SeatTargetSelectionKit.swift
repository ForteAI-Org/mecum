//
//  SeatTargetSelectionKit.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// TargetSelectionStatus is one coherent, revisioned reading of the selection:
/// which window is selected, which members could be, which could not and why,
/// and whether the agent may act on the target.
///
/// The revision exists so a consumer can tell a reading it has already seen from
/// a newer one. It is not permission to send anything: a Command is checked
/// against its observation and against the gate where input is admitted, however
/// recently this value said `operational`.
nonisolated package struct TargetSelectionStatus: Sendable, Equatable {

    package let revision: UInt64

    /// The last reading the assignment nucleus answered, nil until one has been
    /// folded in. Membership, attribution and containment stay its facts.
    package let assignment: AssignmentStatus?

    package let selected  : SelectedTarget?
    package let candidates: [WindowIdentity]
    package let ineligible: [WindowIdentity: EligibilityRefusal]
    package let operability: TargetOperability

    package init(
        revision   : UInt64,
        assignment : AssignmentStatus?,
        selected   : SelectedTarget?,
        candidates : [WindowIdentity],
        ineligible : [WindowIdentity: EligibilityRefusal],
        operability: TargetOperability
    ) {
        self.revision    = revision
        self.assignment  = assignment
        self.selected    = selected
        self.candidates  = candidates
        self.ineligible  = ineligible
        self.operability = operability
    }
}

/// SeatTargetSelectionKit composes the selection policy with the assignment
/// nucleus that was already committed: it borrows a `SeatAssignmentKit`, folds
/// readings through it, and re-decides the target against the membership that
/// kit holds.
///
/// ## What it composes, and what it does not duplicate
///
/// Lifecycle, attribution, membership, containment, focus and restitution stay
/// in `SeatAssignmentKit`; `AssignmentStatus` is carried through unchanged.
/// Nothing here rebuilds them, and nothing here turns one of their facts into a
/// selection fact: an attribution is not an appearance, two agreeing frames are
/// not a raise, a return from an uncertain absence is not a reappearance, and
/// the order of the members is Window ID order.
///
/// ## Ownership and reference semantics
///
/// The assignment kit is borrowed, not owned: the consumer composes both and may
/// drive the assignment directly. Every call here re-reads the lifecycle first,
/// so an assignment released, stopped or exited through the other kit is noticed
/// at the next selection call and gives the selection up with it.
///
/// ## It is preparatory and internal
///
/// It exposes no public surface, is reachable from no legacy send, opens no new
/// input path and fabricates no Frame and no Observation Reference. Admitting a
/// Command against an observation is the third step's work.
package final class SeatTargetSelectionKit {

    private let assignment: SeatAssignmentKit

    package private(set) var core = TargetSelectionCore()

    /// Changes whenever anything above does, so a consumer can tell a reading it
    /// has already seen from a newer one.
    package private(set) var revision: UInt64 = 0

    package private(set) var lastAssignmentStatus: AssignmentStatus?

    /// The assignment generation the recorded facts belong to. A different one
    /// means another instance was handed over, and the facts of the previous
    /// assignment are not carried into it.
    private var assignmentGeneration: UInt64?

    package init(assignment: SeatAssignmentKit) {
        self.assignment = assignment
    }

    package var selected: SelectedTarget? { core.selected }

    /// The versioned observational boundary: it advances whenever the selection
    /// moves to another surface or is given up.
    package var selectionGeneration: UInt64 { core.generation }

    /// What is qualified about the signals this policy needs, reported apart
    /// from what the offline suites establish about the policy itself.
    package var evidenceReport: SelectionEvidenceReport { .current }

    // MARK: Membership, through the assignment nucleus

    /// Folds one reading in through the assignment nucleus and re-decides the
    /// target. The assignment's own answer is carried through untouched.
    @discardableResult
    package func ingest(
        _ reading           : SurfaceInventoryReading,
        claims              : [HelperRelationClaim] = [],
        within virtualBounds: CGRect,
        displays            : [CGDirectDisplayID: CGRect] = [:],
        at now              : UInt64
    ) -> TargetSelectionStatus {

        let status = assignment.ingest(
            reading,
            claims  : claims,
            within  : virtualBounds,
            displays: displays,
            at      : now
        )
        // The fold comes first, so that a reading of a newly handed over
        // instance is not discarded with the previous assignment's facts.
        refold()
        lastAssignmentStatus = status
        return makeStatus()
    }

    /// Discards a member on confirmed evidence of its closure and hands the
    /// selection back: to the parent the closed surface was attested to belong
    /// to when that parent is still eligible and unblocked, otherwise to the
    /// most recent qualified survivor. An absence is refused by the assignment
    /// nucleus and changes nothing here either.
    @discardableResult
    package func confirmClosure(
        of windowNumber: Int,
        evidence       : ClosureEvidence
    ) -> TargetSelectionStatus {

        let identity  = assignment.inventory.surfaces[windowNumber]?.identity
        let discarded = assignment.confirmClosure(of: windowNumber, evidence: evidence)

        if discarded, let identity {
            core.forget(identity, members: assignment.inventory.members)
        }
        refold()
        return makeStatus()
    }

    // MARK: Facts about the surfaces

    @discardableResult
    package func declareRole(_ claim: SurfaceRoleClaim) -> SelectionClaimRefusal? {
        let refusal = core.declareRole(claim, members: assignment.inventory.members)
        refold()
        return refusal
    }

    @discardableResult
    package func declareParent(_ claim: SurfaceParentClaim) -> SelectionClaimRefusal? {
        let refusal = core.declareParent(claim, members: assignment.inventory.members)
        refold()
        return refusal
    }

    @discardableResult
    package func declareModal(_ claim: ModalRelationClaim) -> SelectionClaimRefusal? {
        let refusal = core.declareModal(claim, members: assignment.inventory.members)
        refold()
        return refusal
    }

    @discardableResult
    package func observeVisibility(_ claim: SurfaceVisibilityClaim) -> SelectionClaimRefusal? {
        let refusal = core.observeVisibility(claim, members: assignment.inventory.members)
        refold()
        return refusal
    }

    @discardableResult
    package func noteRecency(_ claim: RecencyClaim) -> SelectionClaimRefusal? {
        let refusal = core.noteRecency(claim, members: assignment.inventory.members)
        refold()
        return refusal
    }

    // MARK: Selection

    @discardableResult
    package func selectExplicitly(
        _ surface: WindowIdentity
    ) -> Result<SelectedTarget, ExplicitSelectionRefusal> {

        guard assignment.lifecycle.isAssigned else { return .failure(.notAssigned) }
        let outcome = core.selectExplicitly(surface, members: assignment.inventory.members)
        refold()
        return outcome
    }

    // MARK: Reading the state

    package func status(observation: TargetObservationClaim? = nil) -> TargetSelectionStatus {
        refold()
        return makeStatus(observation: observation)
    }

    /// Answers whether the agent may act on the selected target now.
    ///
    /// It adds the containment of the assignment and the validity of the
    /// observation to the causes the policy already knows about. The causes stay
    /// independent: a verified containment does not resolve an uncertain
    /// visibility, and a fresh observation does not resolve a modal doubt.
    package func operability(observation: TargetObservationClaim? = nil) -> TargetOperability {

        var causes = core.suspensions

        if assignment.lifecycle.isAssigned {
            let status = lastAssignmentStatus
            if status?.containmentIsVerified != true {
                causes.append(.containmentNotVerified(blocks: status?.blocks ?? []))
            }
        }
        if let selected = core.selected {
            causes.append(contentsOf: observationCauses(for: selected, observation: observation))
        }
        guard let selected = core.selected, causes.isEmpty else {
            return .suspended(target: core.selected, causes: causes)
        }
        return .operational(selected)
    }

    // MARK: Private

    /// Re-reads the lifecycle and re-decides the selection against the
    /// membership the assignment nucleus holds right now.
    private func refold() {

        let generation = assignment.lifecycle.current?.generation
        let changed    = generation != assignmentGeneration
        assignmentGeneration = generation
        revision &+= 1

        if changed {
            core.endAssignment()
            lastAssignmentStatus = nil
        }
        guard generation != nil else {
            core.endAssignment()
            return
        }
        core.reselect(members: assignment.inventory.members)
    }

    private func makeStatus(observation: TargetObservationClaim? = nil) -> TargetSelectionStatus {
        TargetSelectionStatus(
            revision   : revision,
            assignment : lastAssignmentStatus,
            selected   : core.selected,
            candidates : core.candidates,
            ineligible : core.ineligible,
            operability: operability(observation: observation)
        )
    }

    /// Why the observation offered cannot be acted on, empty when it can.
    private func observationCauses(
        for selected: SelectedTarget,
        observation : TargetObservationClaim?
    ) -> [SelectionSuspension] {

        guard let observation else { return [.observationMissing] }

        var causes: [SelectionSuspension] = []
        if observation.selectionGeneration != selected.generation {
            causes.append(.observationSuperseded(
                observed: observation.selectionGeneration,
                current : selected.generation
            ))
        }
        if observation.surface != selected.surface {
            causes.append(.observationIdentityMismatch(
                observed: observation.surface,
                selected: selected.surface
            ))
        }
        guard let member = assignment.inventory.surfaces[selected.surface.windowNumber],
              member.identity == selected.surface,
              VirtualWindowPlacementCheck.framesMatch(member.reference.frame, observation.frame)
        else {
            causes.append(.observationGeometryStale(selected.surface))
            return causes
        }
        return causes
    }
}

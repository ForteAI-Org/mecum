//
//  SeatAssignmentKit.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// AssignmentStatus is one coherent, revisioned reading of an assignment: what
/// is assigned, what the last folded reading changed, which transfers were asked
/// for, and every reason the set is not contained.
///
/// The revision exists so a consumer can tell a newer reading from one it has
/// already seen. It is not permission to send anything: `containmentIsVerified`
/// is a precondition of admitting input, and identity, observation, the Fence
/// and the Facility gate are still checked where input is admitted.
nonisolated package struct AssignmentStatus: Sendable, Equatable {

    package let revision  : UInt64
    package let assignment: AssignedApplication?

    /// What the folded reading changed about membership.
    package let events: [SurfaceEvent]

    /// Window IDs whose transfer was requested in this episode. They are the
    /// partial effects that survive a timeout or a later refusal.
    package let issuedMoves: [Int]

    package let blocks: [ContainmentBlock]

    /// True only when every member is verified inside the seat on a reading that
    /// could carry the whole application, with nothing in doubt.
    package let containmentIsVerified: Bool

    /// The focus restore calls of this episode, with their maximum and their
    /// overruns of the 8 ms limit.
    package let focusBudget: FocusCallBudget

    package init(
        revision             : UInt64,
        assignment           : AssignedApplication?,
        events               : [SurfaceEvent],
        issuedMoves          : [Int],
        blocks               : [ContainmentBlock],
        containmentIsVerified: Bool,
        focusBudget          : FocusCallBudget
    ) {
        self.revision              = revision
        self.assignment            = assignment
        self.events                = events
        self.issuedMoves           = issuedMoves
        self.blocks                = blocks
        self.containmentIsVerified = containmentIsVerified
        self.focusBudget           = focusBudget
    }
}

/// SeatAssignmentKit is the internal composition of the assigned application
/// nucleus: the lifecycle, the membership inventory, the containment
/// coordinator, the restitution and the focus coordinator, wired together and
/// owned in one place.
///
/// ## What it is, and what it is not
///
/// It is a preparatory internal result. It exposes no public surface, it is not
/// reachable from `AgentSeat` or from any legacy send, and it grants no input
/// authority: the public contract, the removal of the legacy entry points and
/// the migration of the internal callers are the third step's work. Holding an
/// assignment here changes nothing about what the existing paths do.
///
/// ## Reference semantics on purpose
///
/// The five parts have to agree about one application through a sequence of
/// readings, so their coordination is the model and a value copy of it would be
/// a second, silently diverging assignment. Ownership is explicit: the kit owns
/// the four state values for the length of the assignment and borrows the
/// effector, which owns its own primitives.
///
/// ## It reads nothing and calls nothing
///
/// Readings, displays and clock values are handed in; the one thing it asks of
/// the world is a placement, through `SurfaceEffecting`. The shipped effector is
/// unqualified and refuses, so composing this type activates no native path.
package final class SeatAssignmentKit {

    private let effector: any SurfaceEffecting

    package private(set) var lifecycle   = AssignmentLifecycle()
    package private(set) var inventory   = AssignedSurfaceInventory()
    package private(set) var restitution = SurfaceRestitution()
    package private(set) var focus       = AssignmentFocusCoordinator()

    /// Changes whenever anything above does, so a consumer can tell a reading it
    /// has already seen from a newer one.
    package private(set) var revision: UInt64 = 0

    private var containment = ContainmentCoordinator(handoverStartedAtNanoseconds: 0)

    /// True until the handover reading has been folded. It decides which reading
    /// records its surfaces as pre-existing, rather than a flag a caller could
    /// pass twice.
    private var awaitsHandoverReading = false

    package init(effector: any SurfaceEffecting = UnqualifiedSurfaceEffector()) {
        self.effector = effector
    }

    /// The qualification of the effector this kit was composed with, so a report
    /// can say whether any effect was possible at all.
    package var effectorQualification: EffectorQualification { effector.qualification }

    // MARK: Lifecycle

    /// Takes an explicitly handed over instance, or refuses before any effect.
    ///
    /// A success starts the containment budget at the handover instant and opens
    /// one focus episode for the handover, which is a complete operation outside
    /// a Turn. Nothing is moved here: the first reading does that.
    @discardableResult
    package func handOver(
        instance   : ProcessIdentity,
        attestation: InstanceAttestation,
        at now     : UInt64
    ) -> Result<AssignedApplication, AssignmentRefusal> {

        let outcome = lifecycle.accept(instance: instance, attestation: attestation, at: now)
        guard case .success(let assignment) = outcome else { return outcome }

        inventory             = AssignedSurfaceInventory()
        containment           = ContainmentCoordinator(
            handoverStartedAtNanoseconds: assignment.handoverStartedAtNanoseconds
        )
        awaitsHandoverReading = true
        focus.beginEpisode()
        revision &+= 1
        return outcome
    }

    /// Ends the assignment because the instance exited.
    ///
    /// There is no restitution: the windows went with the process. An exit
    /// reported for another lifetime is ignored, which is what keeps a reused
    /// PID from ending an assignment it never had.
    @discardableResult
    package func noteExit(of instance: ProcessIdentity) -> AssignedApplication? {
        guard let ended = lifecycle.noteExit(of: instance) else { return nil }
        inventory = AssignedSurfaceInventory()
        focus.endEpisode()
        revision &+= 1
        return ended
    }

    /// Gives the application back on the consumer's explicit request.
    ///
    /// The authority to send input ends here, before any window moves. The
    /// windows are then returned as far as valid destinations allow, and what is
    /// left is an explicit cleanup obligation rather than a success.
    @discardableResult
    package func release(
        chosenDisplays: [Int: CGDirectDisplayID] = [:],
        displays      : [CGDirectDisplayID: CGRect] = [:]
    ) -> RestitutionOutcome {

        guard lifecycle.isAssigned else { return refusedRestitution() }
        let members = inventory.heldMembers
        lifecycle.release(reason: .explicitRelease)
        focus.endEpisode()
        return giveBack(members: members, chosenDisplays: chosenDisplays, displays: displays)
    }

    /// Stops the seat, which ends the assignment it held and refuses every later
    /// handover. The windows are returned on the same terms as an explicit
    /// release.
    @discardableResult
    package func stopSeat(
        chosenDisplays: [Int: CGDirectDisplayID] = [:],
        displays      : [CGDirectDisplayID: CGRect] = [:]
    ) -> RestitutionOutcome {

        let members     = inventory.heldMembers
        let wasAssigned = lifecycle.isAssigned
        lifecycle.stopSeat()
        focus.endEpisode()
        guard wasAssigned else {
            revision &+= 1
            return refusedRestitution()
        }
        return giveBack(members: members, chosenDisplays: chosenDisplays, displays: displays)
    }

    /// Records which members are drawn inside another window of the same
    /// application, so the seat neither owes their return nor is refused a
    /// handback over them. The selection nucleus is the only thing that knows
    /// it, and it hands the whole set in on every fold.
    package func noteAttachedSurfaces(_ identities: Set<WindowIdentity>) {
        inventory.noteAttachedSurfaces(identities)
    }

    // MARK: Membership and containment

    /// Folds one reading in, asks for the transfers it allows, and answers the
    /// status that results.
    ///
    /// The first reading after a handover records its surfaces as pre-existing
    /// **members**: the baseline is not an exemption, and a window the person
    /// already had open in the assigned application is contained like the rest,
    /// with its original frame kept for the return.
    ///
    /// A failed reading changes nothing at all and is reported as such. An
    /// incomplete one keeps the surfaces it carried and keeps the gate closed.
    /// Either way the pass is noted on the containment clock first, so neither
    /// of them spends a containment budget it produced no evidence for.
    @discardableResult
    package func ingest(
        _ reading           : SurfaceInventoryReading,
        claims              : [HelperRelationClaim] = [],
        within virtualBounds: CGRect,
        displays            : [CGDirectDisplayID: CGRect] = [:],
        spaceOf             : ((Int) -> Int?)? = nil,
        at now              : UInt64
    ) -> AssignmentStatus {

        guard let assignment = lifecycle.current else {
            return makeStatus(events: [], blocks: [.notAssigned], isContained: false)
        }
        // Before the early return for a failed read, because a read that failed
        // is the clearest stretch of time the budgets must not be charged for.
        containment.notePass(completeness: reading.completeness, at: now)

        if case .unavailable(let reason) = reading.completeness {
            return makeStatus(
                events     : [],
                blocks     : [.readingUnavailable(reason: reason)],
                isContained: false
            )
        }

        let attributor = SurfaceAttributor(instance: assignment.instance, claims: claims)
        let events     = inventory.fold(
            reading,
            attributor: attributor,
            within    : virtualBounds,
            displays  : displays,
            spaceOf   : spaceOf,
            at        : now,
            isHandover: awaitsHandoverReading
        )
        awaitsHandoverReading = false
        // Between the fold and the plan, which is where a surface first exists
        // and the pause it did not live through is already accounted for.
        containment.noteSurfaces(inventory.members)

        let plan = containment.plan(
            members      : inventory.members,
            uncertain    : inventory.uncertain,
            completeness : inventory.completeness,
            virtualBounds: virtualBounds,
            at           : now
        )
        for move in plan.moves {
            switch effector.requestMove(of: move.identity, to: move.destinationFrame) {
                case .issued:
                    containment.noteMoveIssued(move.windowNumber)
                    inventory.noteContainmentRequested(of: move.windowNumber)
                case .refused(let refusal):
                    containment.noteMoveRefused(move.windowNumber, refusal)
            }
        }
        // Re-planning after the requests is what turns the moves into the state
        // they left behind: attempts spent, refusals named, deadlines counted.
        let settled = plan.moves.isEmpty ? plan : containment.plan(
            members      : inventory.members,
            uncertain    : inventory.uncertain,
            completeness : inventory.completeness,
            virtualBounds: virtualBounds,
            at           : now
        )
        return makeStatus(events: events, blocks: settled.blocks, isContained: settled.isContained)
    }

    /// Discards a member on confirmed evidence of its closure. An absence is
    /// refused: the assignment and the other windows are unaffected.
    @discardableResult
    package func confirmClosure(of windowNumber: Int, evidence: ClosureEvidence) -> Bool {
        let discarded = inventory.confirmClosure(of: windowNumber, evidence: evidence)
        if discarded { revision &+= 1 }
        return discarded
    }

    /// Opens the next containment episode on the consumer's explicit request,
    /// after a refusal or a transfer that did not land. Nothing retries itself.
    package func rearmContainment() {
        containment.rearm()
        revision &+= 1
    }

    // MARK: Focus

    /// Opens a focus episode for a Turn. The handover opens its own.
    package func beginFocusEpisode() {
        focus.beginEpisode()
        revision &+= 1
    }

    package func prepareFocus(_ preparation: FocusPreparation) {
        focus.prepare(preparation)
        revision &+= 1
    }

    /// Decides whether the one automatic attempt may be spent now.
    ///
    /// Incomplete containment is not a parameter and not a reason to refuse:
    /// that is the limited exception, and it waives nothing else. Input stays
    /// closed whatever this answers.
    package func decideFocusAttempt(
        at now             : UInt64,
        userIntentPrevails : Bool,
        topologyIsUnchanged: Bool
    ) -> FocusAttemptDecision {

        let decision = focus.decide(
            at                 : now,
            userIntentPrevails : userIntentPrevails,
            topologyIsUnchanged: topologyIsUnchanged
        )
        revision &+= 1
        return decision
    }

    /// Records one complete restore call, measured entry to exit by the restorer
    /// itself, and opens the verification window.
    package func noteFocusRequest(
        destination           : WindowIdentity,
        restoreCallNanoseconds: UInt64,
        returnedAt            : UInt64
    ) {
        focus.noteRequest(
            destination           : destination,
            restoreCallNanoseconds: restoreCallNanoseconds,
            returnedAt            : returnedAt
        )
        revision &+= 1
    }

    package func observeFocus(frontmost: WindowIdentity?, at now: UInt64) -> FocusVerification {
        focus.observe(frontmost: frontmost, at: now)
    }

    package func noteLateActivation(isCorrelated: Bool, at now: UInt64) -> LateActivationDecision {
        focus.noteLateActivation(isCorrelated: isCorrelated, at: now)
    }

    @discardableResult
    package func rearmFocus(hasFreshEvidence: Bool, previousEffectsReconciled: Bool) -> Bool {
        let rearmed = focus.rearm(
            hasFreshEvidence         : hasFreshEvidence,
            previousEffectsReconciled: previousEffectsReconciled
        )
        if rearmed { revision &+= 1 }
        return rearmed
    }

    // MARK: Restitution

    /// Asks again for the surfaces that had nowhere valid to go, with the
    /// destinations the consumer has now chosen. It carries no input authority
    /// and opens no Turn: it is the cleanup obligation the release left behind.
    @discardableResult
    package func completeRestitution(
        chosenDisplays: [Int: CGDirectDisplayID] = [:],
        displays      : [CGDirectDisplayID: CGRect] = [:]
    ) -> RestitutionOutcome {

        let plan = restitution.plan(chosenDisplays: chosenDisplays, displays: displays)
        var issued: [SurfaceReturn]    = []
        var blocks: [RestitutionBlock] = plan.blocks

        for surfaceReturn in plan.returns {
            switch effector.requestMove(of: surfaceReturn.identity, to: surfaceReturn.destinationFrame) {
                case .issued:
                    restitution.noteIssued(
                        surfaceReturn.windowNumber,
                        destination: surfaceReturn.destinationFrame
                    )
                    issued.append(surfaceReturn)
                case .refused(let refusal):
                    blocks.append(
                        .effectRefused(windowNumber: surfaceReturn.windowNumber, refusal: refusal)
                    )
            }
        }
        revision &+= 1
        return RestitutionOutcome(
            issuedReturns          : issued,
            blocks                 : blocks,
            inputAuthorityIsRevoked: true,
            retainsVirtualDisplay  : !restitution.outstanding.isEmpty
        )
    }

    /// Folds one reading of the returning windows in and answers which of them
    /// two agreeing readings have now put at their destination.
    @discardableResult
    package func confirmReturns(observations: [Int: CGRect]) -> [Int] {
        let verified = restitution.confirm(observations: observations)
        if !verified.isEmpty { revision &+= 1 }
        return verified
    }

    // MARK: Private

    /// Turns the surfaces the seat owes a return into the obligation, and drops
    /// the membership the assignment was holding.
    ///
    /// The callers hand in `inventory.heldMembers` and not `inventory.members`:
    /// a member is any window of the assigned application, so passing members
    /// would open a return for a window nobody ever moved, which nothing public
    /// can discharge and which a handback would then be refused over forever.
    private func giveBack(
        members       : [AssignedSurface],
        chosenDisplays: [Int: CGDirectDisplayID],
        displays      : [CGDirectDisplayID: CGRect]
    ) -> RestitutionOutcome {

        restitution.begin(members: members)
        inventory = AssignedSurfaceInventory()
        return completeRestitution(chosenDisplays: chosenDisplays, displays: displays)
    }

    /// The answer to a release of something that was never assigned: a rejection
    /// before any effect, told apart from an incomplete return by its block.
    private func refusedRestitution() -> RestitutionOutcome {
        RestitutionOutcome(
            issuedReturns          : [],
            blocks                 : [.notAssigned],
            inputAuthorityIsRevoked: true,
            retainsVirtualDisplay  : !restitution.outstanding.isEmpty
        )
    }

    private func makeStatus(
        events     : [SurfaceEvent],
        blocks     : [ContainmentBlock],
        isContained: Bool
    ) -> AssignmentStatus {

        revision &+= 1
        return AssignmentStatus(
            revision             : revision,
            assignment           : lifecycle.current,
            events               : events,
            issuedMoves          : containment.issuedMoves,
            blocks               : blocks,
            containmentIsVerified: isContained,
            focusBudget          : focus.budget
        )
    }
}

//
//  TargetSelectionCore.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// TargetSelectionCore is the policy half of the current window: which member
/// surfaces may be a target, which of them modality leaves available, which one
/// is selected, and every reason the agent may not act on it yet.
///
/// ## It holds no membership of its own
///
/// Membership, lifecycle, attribution and containment stay in the assignment
/// nucleus. Every operation here takes the members of `AssignedSurfaceInventory`
/// as they are and adds only what selection needs: a role, a visibility, a
/// parent, a modal scope and a qualified recency, each on its own evidence. A
/// second membership model next to the committed one is exactly what this type
/// must not become.
///
/// ## The policy, in the order it is applied
///
/// 1. Modal constraints first, inside their scope. A blocked surface is never a
///    candidate, whatever its recency and whoever asks for it.
/// 2. A standing choice, when there is one and it is still a candidate: the
///    consumer's explicit selection, or the parent a closing dialog returned to.
///    It stands until a new qualified event or until it stops being a candidate.
/// 3. Otherwise the most recent qualified appearance, reappearance or return to
///    the front.
/// 4. When that order was not observed and more than one candidate remains, the
///    consumer is asked to choose. Nothing is inferred from Window IDs, from the
///    order of the members or from the order the claims arrived in.
///
/// ## Selected is not operational
///
/// Moving the selection advances the generation, which invalidates the previous
/// observation at once. Whether the agent may act is a separate question that
/// adds containment, the assignment's own blocks and the observation to the
/// causes computed here, and one resolved cause never resolves another.
///
/// It reads nothing and calls nothing: readings, claims and clock values are
/// handed in, which is why the whole of it is a unit test with no display.
nonisolated package struct TargetSelectionCore: Sendable {

    /// What the selection knows about one surface, each fact recorded only from
    /// evidence that can carry it.
    nonisolated package struct SurfaceFacts: Sendable, Equatable {

        package fileprivate(set) var role      : SurfaceRole?
        package fileprivate(set) var visibility: SurfaceVisibility?
        package fileprivate(set) var parent    : WindowIdentity?

        fileprivate init(
            role      : SurfaceRole?       = nil,
            visibility: SurfaceVisibility? = nil,
            parent    : WindowIdentity?    = nil
        ) {
            self.role       = role
            self.visibility = visibility
            self.parent     = parent
        }
    }

    package private(set) var facts   : [WindowIdentity: SurfaceFacts] = [:]
    package private(set) var recency = RecencyOrder()
    package private(set) var modality = ModalConstraints()

    package private(set) var selected  : SelectedTarget?
    package private(set) var generation: UInt64 = 0

    /// The eligible, unblocked members, in Window ID order.
    package private(set) var candidates: [WindowIdentity] = []

    /// Every member that may not be a target, with the reason.
    package private(set) var ineligible: [WindowIdentity: EligibilityRefusal] = [:]

    /// The modal blocks in force, reported whether or not they are the reason
    /// the input waits.
    package private(set) var modalBlocks: [ModalConstraints.Block] = []

    package private(set) var suspensions: [SelectionSuspension] = []

    /// A selection that is not the most recent qualified event: the consumer's
    /// explicit choice, or the parent a closing dialog handed back to. It is
    /// dropped by the next qualified event, which is how the automatic policy
    /// comes back, and by the surface ceasing to be a candidate.
    private var standingSurface: WindowIdentity?
    private var standingReason : SelectedTarget.Reason = .explicitChoice

    package init() {}

    // MARK: Facts about a surface

    /// Records what a surface is. The claim is refused when its provenance
    /// cannot carry a role, and a refused claim changes nothing.
    @discardableResult
    package mutating func declareRole(
        _ claim: SurfaceRoleClaim,
        members: [AssignedSurface]
    ) -> SelectionClaimRefusal? {

        guard claim.provenance.attests(.surfaceRole) else {
            return .provenanceCannotCarry(conclusion: .surfaceRole, provenance: claim.provenance)
        }
        facts[claim.surface, default: SurfaceFacts()].role = claim.role
        reselect(members: members)
        return nil
    }

    /// Records whose surface this is, for the one decision that uses it: the
    /// return when a dialog closes.
    @discardableResult
    package mutating func declareParent(
        _ claim: SurfaceParentClaim,
        members: [AssignedSurface]
    ) -> SelectionClaimRefusal? {

        guard claim.provenance.attests(.parentRelation) else {
            return .provenanceCannotCarry(conclusion: .parentRelation, provenance: claim.provenance)
        }
        guard claim.child != claim.parent else { return .relationIsSelfReferential(claim.child) }
        guard !parentageLeadsBack(from: claim.parent, to: claim.child) else {
            return .relationIsCyclic(claim.child)
        }
        facts[claim.child, default: SurfaceFacts()].parent = claim.parent
        reselect(members: members)
        return nil
    }

    /// Records a modal relation, or keeps the reason it could not be established
    /// as a doubt that suspends the input.
    @discardableResult
    package mutating func declareModal(
        _ claim: ModalRelationClaim,
        members: [AssignedSurface]
    ) -> SelectionClaimRefusal? {

        let refusal = modality.declare(claim)
        reselect(members: members)
        return refusal
    }

    /// Records one visibility reading. An established hiding or minimising takes
    /// eligibility away without touching membership; an uncertain reading takes
    /// nothing away and suspends the input.
    @discardableResult
    package mutating func observeVisibility(
        _ claim: SurfaceVisibilityClaim,
        members: [AssignedSurface]
    ) -> SelectionClaimRefusal? {

        guard claim.provenance.attests(.visibilityState) else {
            return .provenanceCannotCarry(conclusion: .visibilityState, provenance: claim.provenance)
        }
        facts[claim.surface, default: SurfaceFacts()].visibility = claim.state
        reselect(members: members)
        return nil
    }

    // MARK: Recency

    /// Folds one reported event into the Window Recency, or refuses it.
    ///
    /// A qualified event is, by definition, the surface established visible and
    /// interactive, so it records that too rather than requiring a second claim
    /// for the same fact. It also drops any standing choice: a later qualified
    /// event is what puts the automatic policy back in charge after the consumer
    /// selected explicitly or after a dialog returned to its parent.
    @discardableResult
    package mutating func noteRecency(
        _ claim: RecencyClaim,
        members: [AssignedSurface]
    ) -> SelectionClaimRefusal? {

        if let refusal = claim.unqualifiedReason { return refusal }
        guard members.contains(where: { $0.identity == claim.surface }) else {
            return .surfaceIsNotAMember(claim.surface)
        }
        guard facts[claim.surface]?.role?.isTransientMenu != true else {
            return .transientMenuHasNoRecency(claim.surface)
        }
        let recorded = recency.record(
            claim.surface,
            signal: claim.signal,
            at    : claim.observedAtNanoseconds
        )
        guard recorded else { return .recencyIsNotNewer(claim.surface) }

        facts[claim.surface, default: SurfaceFacts()].visibility = .visibleInteractive
        standingSurface = nil
        reselect(members: members)
        return nil
    }

    // MARK: Selection

    /// Takes the consumer's own choice of target.
    ///
    /// The choice is an alternative to the automatic recency and not a way
    /// around anything: an ineligible or modally blocked surface is refused
    /// here, and containment, observation and the other causes of the gate still
    /// decide whether the chosen target may be acted on. It writes no recency,
    /// so the history of appearances is left exactly as it was observed.
    @discardableResult
    package mutating func selectExplicitly(
        _ surface: WindowIdentity,
        members  : [AssignedSurface]
    ) -> Result<SelectedTarget, ExplicitSelectionRefusal> {

        let isMember = members.contains { $0.identity == surface }
        if let refusal = eligibility(of: surface, isMember: isMember) {
            guard refusal != .notAMember else { return .failure(.surfaceIsNotAMember(surface)) }
            return .failure(.surfaceIsNotEligible(refusal))
        }
        let blocks = modality.blocks(among: members.map(\.identity))
        if let block = blocks.first(where: { $0.blocked == surface }) {
            return .failure(.modallyBlocked(by: block.modal))
        }
        standingSurface = surface
        standingReason  = .explicitChoice
        reselect(members: members)

        guard let selected, selected.surface == surface else {
            return .failure(.surfaceIsNotEligible(ineligible[surface] ?? .notAMember))
        }
        return .success(selected)
    }

    /// Drops everything known about a surface whose closure was confirmed, and
    /// hands the selection back.
    ///
    /// `members` must already be the membership without that surface. When the
    /// closed surface was the target, the parent it was attested to belong to
    /// becomes the standing choice; a parent that is no longer a candidate
    /// simply does not stand, and the automatic policy answers instead.
    package mutating func forget(_ surface: WindowIdentity, members: [AssignedSurface]) {

        let wasSelected = selected?.surface == surface
        let parent      = facts[surface]?.parent ?? modality.parentNamed(by: surface)

        facts[surface] = nil
        recency.forget(surface)
        modality.forget(surface)
        if standingSurface == surface { standingSurface = nil }

        if wasSelected, let parent, parent != surface {
            standingSurface = parent
            standingReason  = .returnToParent
        }
        reselect(members: members)
    }

    /// Gives up the selection and everything the facts said about the surfaces
    /// of an assignment that is over. The generation advances, so an observation
    /// taken under the assignment cannot be acted on afterwards.
    package mutating func endAssignment() {

        facts           = [:]
        recency         = RecencyOrder()
        modality        = ModalConstraints()
        standingSurface = nil
        candidates      = []
        ineligible      = [:]
        modalBlocks     = []
        clearSelection()
        suspensions     = [.notAssigned]
    }

    /// Re-decides the selection against the membership as it stands now.
    ///
    /// Every operation above ends here, so the stored candidates, refusals,
    /// blocks and causes are always the answer for the members last handed in.
    package mutating func reselect(members: [AssignedSurface]) {

        let identities = members.map(\.identity)

        var refusals: [WindowIdentity: EligibilityRefusal] = [:]
        var eligible: [WindowIdentity]                     = []

        for surface in identities {
            if let refusal = eligibility(of: surface, isMember: true) {
                refusals[surface] = refusal
            } else {
                eligible.append(surface)
            }
        }

        let withdrawn = Set(identities.filter {
            facts[$0]?.visibility == .withdrawnEstablished
        })
        modalBlocks = modality.blocks(among: identities, excluding: withdrawn)
        let blocked = Set(modalBlocks.map(\.blocked))

        ineligible = refusals
        candidates = eligible.filter { !blocked.contains($0) }

        var requiredChoice: [WindowIdentity] = []
        if let standing = standingSurface, candidates.contains(standing) {
            settle(on: standing, reason: standingReason)
        } else {
            standingSurface = nil
            requiredChoice  = chooseAutomatically()
        }
        suspensions = causes(members: members, requiredChoice: requiredChoice)
    }

    // MARK: Private

    /// Why this surface may not be a target, and nil when it may.
    ///
    /// An uncertain visibility deliberately does not refuse: taking eligibility
    /// away on a reading that decided nothing would replace the current target
    /// on the strength of a doubt. It suspends instead.
    private func eligibility(of surface: WindowIdentity, isMember: Bool) -> EligibilityRefusal? {

        guard isMember else { return .notAMember }
        guard let role = facts[surface]?.role else { return .roleNotRead }
        guard !role.isTransientMenu else { return .transientMenu(of: facts[surface]?.parent) }
        guard role.mayBeSelected else { return .roleCannotBeSelected(role) }
        guard let visibility = facts[surface]?.visibility else { return .visibilityNotRead }

        switch visibility {
            case .visibleInteractive, .uncertain: return nil
            case .hiddenEstablished:              return .hiddenEstablished
            case .minimisedEstablished:           return .minimisedEstablished
            case .withdrawnEstablished:           return .withdrawnEstablished
        }
    }

    /// Applies the automatic policy and answers the candidates the consumer has
    /// to choose between, empty when it decided.
    private mutating func chooseAutomatically() -> [WindowIdentity] {

        switch recency.mostRecent(among: candidates) {
            case .one(let surface):
                settle(on: surface, reason: .qualifiedRecency)
                return []

            case .ambiguous(let tied):
                clearSelection()
                return tied

            case .notObserved:
                guard candidates.count == 1, let only = candidates.first else {
                    clearSelection()
                    return candidates.sorted { $0.windowNumber < $1.windowNumber }
                }
                settle(on: only, reason: .onlyCandidate)
                return []
        }
    }

    /// Moves the selection. The generation advances only when the surface
    /// changes: a target that stayed the target for a new reason is the same
    /// target, and its observation is still of it.
    private mutating func settle(on surface: WindowIdentity, reason: SelectedTarget.Reason) {

        guard let current = selected, current.surface == surface else {
            generation &+= 1
            selected = SelectedTarget(surface: surface, generation: generation, reason: reason)
            return
        }
        guard current.reason != reason else { return }
        selected = SelectedTarget(surface: surface, generation: current.generation, reason: reason)
    }

    private mutating func clearSelection() {
        guard selected != nil else { return }
        generation &+= 1
        selected = nil
    }

    /// Every cause of suspension the selection itself knows about. Containment
    /// and the observation are added where they are known, and none of these
    /// causes resolves another.
    private func causes(
        members       : [AssignedSurface],
        requiredChoice: [WindowIdentity]
    ) -> [SelectionSuspension] {

        var causes: [SelectionSuspension] = []

        if candidates.isEmpty { causes.append(.noEligibleTarget) }
        if !requiredChoice.isEmpty {
            causes.append(.explicitSelectionRequired(candidates: requiredChoice))
        }
        // A block is a cause only where it is the reason nothing is usable.
        // While a modal is itself the target, the windows it stops are exactly
        // where they should be.
        if selected == nil {
            for block in modalBlocks {
                causes.append(.modalBlock(modal: block.modal, blocked: block.blocked))
            }
        }
        for doubt in modality.doubts {
            causes.append(.modalRelationInDoubt(doubt))
        }
        for member in members where facts[member.identity]?.visibility == .uncertain {
            causes.append(.visibilityUncertain(member.identity))
        }
        if let selected, let member = members.first(where: { $0.identity == selected.surface }) {
            if member.presence == .absentUncertain {
                causes.append(.selectedSurfaceAbsent(member.identity))
            }
            if !member.isVerified {
                causes.append(.selectedSurfaceNotVerified(member.identity))
            }
        }
        return causes
    }

    /// Follows the recorded parent links and answers whether they lead back,
    /// which is what keeps a claimed parentage from closing a loop.
    private func parentageLeadsBack(from start: WindowIdentity, to target: WindowIdentity) -> Bool {

        var visited: Set<WindowIdentity> = []
        var current: WindowIdentity      = start

        while visited.insert(current).inserted {
            guard let next = facts[current]?.parent else { return false }
            if next == target { return true }
            current = next
        }
        return false
    }
}

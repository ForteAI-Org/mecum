//
//  ModalConstraints.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// ModalDoubt is a modal relation that could not be established, kept as a fact
/// of its own. A doubt suspends the input and creates no block: the nucleus
/// neither invents a constraint it cannot verify nor lets an unverifiable claim
/// pass as permission.
nonisolated package enum ModalDoubt: Sendable, Equatable {

    /// The claim arrived on evidence that cannot carry a modal relation.
    case relationNotQualified(surface: WindowIdentity, provenance: SelectionProvenance)

    /// Two qualified claims about the same surface disagree about its scope.
    case claimsDisagree(surface: WindowIdentity)

    /// The relation would close a loop with the ones already recorded, so the
    /// consumer's model of modality is incoherent.
    case relationIsCyclic(surface: WindowIdentity)

    /// The surface the doubt is about.
    package var surface: WindowIdentity {
        switch self {
            case .relationNotQualified(let surface, _): surface
            case .claimsDisagree(let surface):          surface
            case .relationIsCyclic(let surface):        surface
        }
    }
}

/// ModalConstraints is the modal half of the selection: which member surfaces
/// block which, and which relations are in doubt.
///
/// ## Precedence, inside the scope of the relation
///
/// A blocked surface is not a candidate for selection, whatever its recency and
/// whoever asks for it. Blocking follows the recorded scopes one step at a time,
/// which is all nesting needs: with C modal to B and B modal to A, C blocks B
/// and B blocks A, so only C is selectable, and closing C frees B alone.
///
/// ## A hidden modal still blocks
///
/// Blocking depends on membership, never on visibility. A modal that was hidden
/// or minimised keeps its block, because a surface that is out of sight has not
/// stopped stopping the windows underneath it. That is also why an absence from
/// a reading does not lift a block: the inventory keeps the member, so the block
/// stays until the closure is confirmed.
///
/// ## A doubt is not a block and not a permission
///
/// A claim on evidence that cannot carry modality, two qualified claims that
/// disagree, or a relation that closes a loop are recorded as doubts. They
/// suspend input without inventing a constraint, and a disagreement leaves the
/// scope that was already recorded in place rather than letting the later claim
/// unblock a modal.
///
/// It reads nothing: every claim and every member list is handed in.
nonisolated package struct ModalConstraints: Sendable, Equatable {

    /// One surface blocking one other surface, both members of the assignment.
    nonisolated package struct Block: Sendable, Equatable {

        package let modal  : WindowIdentity
        package let blocked: WindowIdentity

        package init(modal: WindowIdentity, blocked: WindowIdentity) {
            self.modal   = modal
            self.blocked = blocked
        }
    }

    package private(set) var scopes: [WindowIdentity: ModalScope] = [:]
    package private(set) var doubts: [ModalDoubt] = []

    package init() {}

    /// Records one claim, or refuses it and keeps the reason as a doubt.
    @discardableResult
    package mutating func declare(_ claim: ModalRelationClaim) -> SelectionClaimRefusal? {

        guard claim.provenance.attests(.modalRelation) else {
            note(.relationNotQualified(surface: claim.modal, provenance: claim.provenance))
            return .provenanceCannotCarry(conclusion: .modalRelation, provenance: claim.provenance)
        }
        if case .window(let blocked) = claim.scope {
            guard blocked != claim.modal else {
                note(.relationIsCyclic(surface: claim.modal))
                return .relationIsSelfReferential(claim.modal)
            }
            guard !leadsBack(from: blocked, to: claim.modal) else {
                note(.relationIsCyclic(surface: claim.modal))
                return .relationIsCyclic(claim.modal)
            }
        }
        guard let recorded = scopes[claim.modal] else {
            scopes[claim.modal] = claim.scope
            return nil
        }
        guard recorded == claim.scope else {
            note(.claimsDisagree(surface: claim.modal))
            return .relationContradictsRecordedScope(claim.modal)
        }
        // Re-attesting the recorded scope is how a consumer settles a
        // contradiction it has resolved outside.
        doubts.removeAll { $0.surface == claim.modal }
        return nil
    }

    /// Drops everything recorded about a surface whose closure was confirmed.
    package mutating func forget(_ surface: WindowIdentity) {
        scopes[surface] = nil
        doubts.removeAll { $0.surface == surface }
    }

    /// The window a `.window` scope names for this modal, which is the surface a
    /// closing dialog hands the selection back to when no parent was attested.
    package func parentNamed(by modal: WindowIdentity) -> WindowIdentity? {
        guard case .window(let parent)? = scopes[modal] else { return nil }
        return parent
    }

    /// Every block in force among these members, in a stable order so a report
    /// reads the same on every run.
    package func blocks(among members: [WindowIdentity]) -> [Block] {

        let present = Set(members)
        var blocks : [Block] = []

        for modal in members {
            guard let scope = scopes[modal] else { continue }
            switch scope {
                case .window(let blocked):
                    guard present.contains(blocked) else { continue }
                    blocks.append(Block(modal: modal, blocked: blocked))

                case .application:
                    for other in members where other != modal {
                        blocks.append(Block(modal: modal, blocked: other))
                    }
            }
        }
        return blocks.sorted {
            ($0.modal.windowNumber, $0.blocked.windowNumber)
                < ($1.modal.windowNumber, $1.blocked.windowNumber)
        }
    }

    private mutating func note(_ doubt: ModalDoubt) {
        guard !doubts.contains(doubt) else { return }
        doubts.append(doubt)
    }

    /// Follows the recorded window scopes from one surface and answers whether
    /// they lead back to another. The visited set bounds the walk even when the
    /// recorded scopes already contain a loop.
    private func leadsBack(from start: WindowIdentity, to target: WindowIdentity) -> Bool {

        var visited: Set<WindowIdentity> = []
        var current: WindowIdentity      = start

        while visited.insert(current).inserted {
            guard case .window(let next)? = scopes[current] else { return false }
            if next == target { return true }
            current = next
        }
        return false
    }
}

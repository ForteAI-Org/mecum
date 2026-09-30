//
//  TargetSelectionCoreTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

@testable import SeatCore
import Testing

/// The selection policy, driven end to end over a real membership inventory:
/// which surfaces may be targets, what modality allows, where a closing dialog
/// hands back to, and what the nucleus refuses to infer.
///
/// Nothing native happens. The suite proves the algorithms and the composition
/// with the committed membership model; it proves nothing about reading a role,
/// a parentage, a modal relation, an order or the origin of a raise on a real
/// system, all of which need their own qualified evidence.
@Suite("The selection policy over a real membership")
struct TargetSelectionCoreTests {

    typealias Fixture = SelectionFixtures

    // MARK: Which surfaces may be a target at all

    @Test("A document, a dialog and an interactive panel may be targets; a tooltip and a decoration may not")
    func rolesDecideEligibility() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13, 14, 15])
        var core    = TargetSelectionCore()

        let roles: [(Int, SurfaceRole)] = [
            (11, .document), (12, .dialog), (13, .interactivePanel),
            (14, .tooltip), (15, .decoration),
        ]
        for (number, role) in roles {
            core.declareRole(Fixture.role(number, role), members: members)
            core.observeVisibility(Fixture.visibility(number, .visibleInteractive), members: members)
        }

        #expect(core.candidates == [11, 12, 13].map(Fixture.identity))
        #expect(core.ineligible[Fixture.identity(14)] == .roleCannotBeSelected(.tooltip))
        #expect(core.ineligible[Fixture.identity(15)] == .roleCannotBeSelected(.decoration))
    }

    @Test("A surface whose role nobody read is not made a target by assumption")
    func unreadRoleIsNotADocument() {

        var folder  = MemberFolder()
        let members = folder.settle([11])
        var core    = TargetSelectionCore()

        core.observeVisibility(Fixture.visibility(11, .visibleInteractive), members: members)
        let refused = core.declareRole(Fixture.role(11, .document, provenance: .windowLevel), members: members)

        #expect(refused == .provenanceCannotCarry(conclusion: .surfaceRole, provenance: .windowLevel))
        #expect(core.ineligible[Fixture.identity(11)] == .roleNotRead)
        #expect(core.selected == nil)
    }

    @Test("A contextual menu is the transient of its parent and never enters the history")
    func contextualMenuIsExcludedFromTheHistory() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 21])
        var core    = Fixture.core(documents: [11], members: members)

        core.declareRole(Fixture.role(21, .contextualMenu), members: members)
        core.declareParent(Fixture.parent(21, of: 11), members: members)
        core.observeVisibility(Fixture.visibility(21, .visibleInteractive), members: members)

        let refused = core.noteRecency(Fixture.event(21, at: 5_000), members: members)

        #expect(refused == .transientMenuHasNoRecency(Fixture.identity(21)))
        #expect(core.ineligible[Fixture.identity(21)] == .transientMenu(of: Fixture.identity(11)))
        #expect(core.candidates == [Fixture.identity(11)])
        #expect(core.selected?.surface == Fixture.identity(11))
        #expect(core.recency.marks[Fixture.identity(21)] == nil)
    }

    // MARK: What moves the recency, and what does not

    @Test("Appearance, reappearance and a return to the front move the recency")
    func theThreeQualifiedEventsMoveTheRecency() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.noteRecency(Fixture.event(11, .appeared, at: 10), members: members)
        #expect(core.selected?.surface == Fixture.identity(11))

        core.noteRecency(Fixture.event(12, .appeared, at: 20), members: members)
        #expect(core.selected?.surface == Fixture.identity(12))

        core.noteRecency(Fixture.event(11, .returnedToFront, at: 30), members: members)
        #expect(core.selected?.surface == Fixture.identity(11))
        #expect(core.selected?.reason == .qualifiedRecency)

        core.observeVisibility(Fixture.visibility(12, .hiddenEstablished), members: members)
        core.noteRecency(Fixture.event(12, .reappeared, at: 40), members: members)
        #expect(core.selected?.surface == Fixture.identity(12))
    }

    @Test("Focus, geometry, attribution, a return from an absence and the kit's own raises are not recency")
    func unqualifiedSignalsDoNotMoveTheTarget() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)
        core.noteRecency(Fixture.event(11, .appeared, at: 10), members: members)

        let refusals = [
            core.noteRecency(Fixture.event(12, .globalApplicationFocusChanged, at: 20), members: members),
            core.noteRecency(Fixture.event(12, .geometryVerified, at: 21), members: members),
            core.noteRecency(Fixture.event(12, .attributedToAssignment, at: 22), members: members),
            core.noteRecency(Fixture.event(12, .returnedFromUncertainAbsence, at: 23), members: members),
            core.noteRecency(Fixture.event(12, .placementIssuedByKit, at: 24), members: members),
            core.noteRecency(
                Fixture.event(12, .returnedToFront, at: 25, provenance: .globalApplicationFocus),
                members: members
            ),
            core.noteRecency(
                Fixture.event(12, .returnedToFront, at: 26, provenance: .memberOrderByWindowID),
                members: members
            ),
            core.noteRecency(
                Fixture.event(12, .returnedToFront, at: 27, origin: .kitPlacement),
                members: members
            ),
            core.noteRecency(
                Fixture.event(12, .returnedToFront, at: 28, origin: .unattributed),
                members: members
            ),
        ]

        #expect(refusals.allSatisfy { $0 != nil })
        #expect(refusals[0] == .signalIsNotRecency(.globalApplicationFocusChanged))
        #expect(refusals[5] == .provenanceCannotCarry(
            conclusion: .frontOrder,
            provenance: .globalApplicationFocus
        ))
        #expect(refusals[7] == .raiseIsNotFromApplication(.kitPlacement))
        #expect(refusals[8] == .raiseIsNotFromApplication(.unattributed))
        #expect(core.selected?.surface == Fixture.identity(11), "None of them moved the target")
        #expect(core.recency.marks[Fixture.identity(12)] == nil)
    }

    @Test("A result that arrives late does not move the target")
    func lateResultDoesNotMoveTheTarget() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.noteRecency(Fixture.event(11, .appeared, at: 10), members: members)
        core.noteRecency(Fixture.event(12, .appeared, at: 30), members: members)
        let late = core.noteRecency(Fixture.event(11, .returnedToFront, at: 20), members: members)

        #expect(late == nil, "An older event about another surface is still recorded")
        #expect(core.selected?.surface == Fixture.identity(12))

        let older = core.noteRecency(Fixture.event(12, .returnedToFront, at: 5), members: members)
        #expect(older == .recencyIsNotNewer(Fixture.identity(12)))
        #expect(core.selected?.surface == Fixture.identity(12))
    }

    // MARK: Nested dialogs, and the return when they close

    @Test("A to B to C returns to the eligible parent as each dialog closes")
    func nestedDialogsReturnToTheParent() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13])
        var core    = Fixture.core(documents: [11], members: members)

        for (number, parent) in [(12, 11), (13, 12)] {
            core.declareRole(Fixture.role(number, .dialog), members: members)
            core.observeVisibility(Fixture.visibility(number, .visibleInteractive), members: members)
            core.declareParent(Fixture.parent(number, of: parent), members: members)
            core.declareModal(Fixture.modal(number, over: parent), members: members)
        }
        core.noteRecency(Fixture.event(11, .appeared, at: 10), members: members)
        core.noteRecency(Fixture.event(12, .appeared, at: 20), members: members)
        core.noteRecency(Fixture.event(13, .appeared, at: 30), members: members)

        #expect(core.candidates == [Fixture.identity(13)], "The blocks leave only the innermost")
        #expect(core.selected?.surface == Fixture.identity(13))

        let afterInner = folder.settle([11, 12])
        core.forget(Fixture.identity(13), members: afterInner)

        #expect(core.selected?.surface == Fixture.identity(12))
        #expect(core.selected?.reason == .returnToParent)

        let afterOuter = folder.settle([11])
        core.forget(Fixture.identity(12), members: afterOuter)

        #expect(core.selected?.surface == Fixture.identity(11))
        #expect(core.selected?.reason == .returnToParent)
        #expect(core.suspensions.isEmpty, "Nothing about the policy is unresolved any more")
    }

    @Test("When the parent is no longer eligible the return goes to the most recent survivor")
    func returnSkipsAnIneligibleParent() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.declareRole(Fixture.role(13, .dialog), members: members)
        core.observeVisibility(Fixture.visibility(13, .visibleInteractive), members: members)
        core.declareParent(Fixture.parent(13, of: 12), members: members)
        core.declareModal(Fixture.modal(13, over: 12), members: members)

        core.noteRecency(Fixture.event(11, .appeared, at: 10), members: members)
        core.noteRecency(Fixture.event(12, .appeared, at: 20), members: members)
        core.noteRecency(Fixture.event(13, .appeared, at: 30), members: members)
        core.observeVisibility(Fixture.visibility(12, .minimisedEstablished), members: members)

        #expect(core.selected?.surface == Fixture.identity(13))

        let survivors = folder.settle([11, 12])
        core.forget(Fixture.identity(13), members: survivors)

        #expect(core.selected?.surface == Fixture.identity(11))
        #expect(core.selected?.reason == .qualifiedRecency)
        #expect(core.ineligible[Fixture.identity(12)] == .minimisedEstablished)
    }

    // MARK: Modal precedence

    @Test("A hidden modal keeps blocking, and with nothing usable the input stays suspended")
    func hiddenModalStillBlocks() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11], members: members)

        core.declareRole(Fixture.role(12, .dialog), members: members)
        core.declareModal(Fixture.modal(12, over: 11), members: members)
        core.observeVisibility(Fixture.visibility(12, .hiddenEstablished), members: members)

        #expect(core.candidates.isEmpty)
        #expect(core.selected == nil)
        #expect(core.suspensions.contains(.noEligibleTarget))
        #expect(core.suspensions.contains(
            .modalBlock(modal: Fixture.identity(12), blocked: Fixture.identity(11))
        ))
    }

    @Test("An application modal leaves only itself selectable")
    func applicationModalBlocksTheRest() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.declareRole(Fixture.role(13, .dialog), members: members)
        core.observeVisibility(Fixture.visibility(13, .visibleInteractive), members: members)
        core.declareModal(Fixture.modal(13, over: nil), members: members)

        #expect(core.candidates == [Fixture.identity(13)])
        #expect(core.selected?.surface == Fixture.identity(13))
    }

    /// DaVinci Resolve's Import Media panel is modal to the application and its
    /// Go to Folder sheet is modal to the panel. Blocking each other, the two
    /// left no candidate and every key was suspended.
    @Test("A sheet on an application modal is not blocked by the modal it stops")
    func sheetOnAnApplicationModalIsSelectable() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13])
        var core    = Fixture.core(documents: [11], members: members)

        for number in [12, 13] {
            core.declareRole(Fixture.role(number, .dialog), members: members)
            core.observeVisibility(Fixture.visibility(number, .visibleInteractive), members: members)
        }
        core.declareModal(Fixture.modal(12, over: nil), members: members)
        core.declareModal(Fixture.modal(13, over: 12), members: members)

        #expect(core.candidates == [Fixture.identity(13)])
        #expect(core.selected?.surface == Fixture.identity(13))
        #expect(!core.suspensions.contains(.noEligibleTarget))
    }

    /// DaVinci Resolve's "project already exists" message opens modal to the
    /// application over its New Project dialog, which is modal to the
    /// application too. Each blocked the other, and the message could not be
    /// answered.
    @Test("Of two application modals the one opened last is selectable, and closing it frees the first")
    func theNewestApplicationModalIsSelectable() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13])
        var core    = Fixture.core(documents: [11], members: members)

        for number in [12, 13] {
            core.declareRole(Fixture.role(number, .dialog), members: members)
            core.observeVisibility(Fixture.visibility(number, .visibleInteractive), members: members)
            core.declareModal(Fixture.modal(number, over: nil), members: members)
        }

        #expect(core.candidates == [Fixture.identity(13)])
        #expect(core.selected?.surface == Fixture.identity(13))

        let remaining = folder.settle([11, 12])
        core.forget(Fixture.identity(13), members: remaining)
        #expect(core.candidates == [Fixture.identity(12)])
    }

    @Test("A modal relation on evidence that cannot carry it is a doubt, never a bypass")
    func unqualifiedModalRelationIsADoubt() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        let refused = core.declareModal(
            Fixture.modal(12, over: 11, provenance: .windowServerAttestedIdentity),
            members: members
        )

        #expect(refused == .provenanceCannotCarry(
            conclusion: .modalRelation,
            provenance: .windowServerAttestedIdentity
        ))
        #expect(core.modalBlocks.isEmpty, "A doubt invents no block")
        #expect(core.suspensions.contains(.modalRelationInDoubt(.relationNotQualified(
            surface   : Fixture.identity(12),
            provenance: .windowServerAttestedIdentity
        ))))
    }

    @Test("Disagreeing qualified claims keep the recorded block and report the contradiction")
    func disagreeingModalClaimsAreReported() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.declareRole(Fixture.role(13, .dialog), members: members)
        core.observeVisibility(Fixture.visibility(13, .visibleInteractive), members: members)
        core.declareModal(Fixture.modal(13, over: 11), members: members)
        let contradiction = core.declareModal(Fixture.modal(13, over: nil), members: members)

        #expect(contradiction == .relationContradictsRecordedScope(Fixture.identity(13)))
        #expect(core.candidates == [Fixture.identity(12), Fixture.identity(13)])
        #expect(core.suspensions.contains(
            .modalRelationInDoubt(.claimsDisagree(surface: Fixture.identity(13)))
        ))
    }

    @Test("A modal relation that closes a loop is refused")
    func cyclicModalRelationIsRefused() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.declareModal(Fixture.modal(12, over: 11), members: members)
        let cyclic = core.declareModal(Fixture.modal(11, over: 12), members: members)

        #expect(cyclic == .relationIsCyclic(Fixture.identity(11)))
        #expect(core.modalBlocks == [
            ModalConstraints.Block(modal: Fixture.identity(12), blocked: Fixture.identity(11)),
        ])
    }

    // MARK: An order nobody observed

    @Test("An initial pair with no verifiable order asks for an explicit selection")
    func initialOrderRequiresAnExplicitChoice() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        let core    = Fixture.core(documents: [11, 12], members: members)

        #expect(core.selected == nil)
        #expect(core.suspensions.contains(.explicitSelectionRequired(
            candidates: [Fixture.identity(11), Fixture.identity(12)]
        )))
        #expect(core.recency.marks.isEmpty, "No order was invented from the Window IDs")
    }

    @Test("A single survivor is selected without any order to establish")
    func singleCandidateNeedsNoOrder() {

        var folder  = MemberFolder()
        let members = folder.settle([12])
        let core    = Fixture.core(documents: [12], members: members)

        #expect(core.selected?.surface == Fixture.identity(12))
        #expect(core.selected?.reason == .onlyCandidate)
    }

    @Test("Simultaneous appearances ask for an explicit selection")
    func simultaneousAppearancesRequireAnExplicitChoice() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13])
        var core    = Fixture.core(documents: [11, 12, 13], members: members)

        core.noteRecency(Fixture.event(11, .appeared, at: 10), members: members)
        core.noteRecency(Fixture.event(12, .appeared, at: 20), members: members)
        core.noteRecency(Fixture.event(13, .appeared, at: 20), members: members)

        #expect(core.selected == nil)
        #expect(core.suspensions.contains(.explicitSelectionRequired(
            candidates: [Fixture.identity(12), Fixture.identity(13)]
        )))
    }

    @Test("The explicit choice writes no history, and a later qualified event takes over again")
    func explicitChoiceThenAutomaticReturn() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        let chosen = core.selectExplicitly(Fixture.identity(11), members: members)

        #expect(chosen == .success(SelectedTarget(
            surface   : Fixture.identity(11),
            generation: core.generation,
            reason    : .explicitChoice
        )))
        #expect(core.recency.marks.isEmpty, "Choosing is not observing an appearance")

        core.noteRecency(Fixture.event(12, .appeared, at: 10), members: members)

        #expect(core.selected?.surface == Fixture.identity(12))
        #expect(core.selected?.reason == .qualifiedRecency)
    }

    @Test("An explicit choice goes around neither modality nor eligibility")
    func explicitChoiceGoesAroundNothing() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12, 13])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.declareRole(Fixture.role(13, .dialog), members: members)
        core.observeVisibility(Fixture.visibility(13, .visibleInteractive), members: members)
        core.declareModal(Fixture.modal(13, over: 11), members: members)
        core.observeVisibility(Fixture.visibility(12, .hiddenEstablished), members: members)

        let blocked  = core.selectExplicitly(Fixture.identity(11), members: members)
        let hidden   = core.selectExplicitly(Fixture.identity(12), members: members)
        let stranger = core.selectExplicitly(Fixture.identity(99), members: members)

        #expect(blocked == .failure(.modallyBlocked(by: Fixture.identity(13))))
        #expect(hidden == .failure(.surfaceIsNotEligible(.hiddenEstablished)))
        #expect(stranger == .failure(.surfaceIsNotAMember(Fixture.identity(99))))
    }

    // MARK: Hiding, minimising and an absence nobody can explain

    @Test("Hiding and minimising take eligibility away and leave membership alone")
    func hidingRemovesEligibilityOnly() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.noteRecency(Fixture.event(11, .appeared, at: 10), members: members)
        core.noteRecency(Fixture.event(12, .appeared, at: 20), members: members)
        core.observeVisibility(Fixture.visibility(12, .hiddenEstablished), members: members)

        #expect(core.selected?.surface == Fixture.identity(11))
        #expect(core.ineligible[Fixture.identity(12)] == .hiddenEstablished)
        #expect(folder.members.count == 2, "Membership persists through a hiding")

        core.noteRecency(Fixture.event(12, .reappeared, at: 30), members: members)
        #expect(core.selected?.surface == Fixture.identity(12))
    }

    @Test("An uncertain absence suspends the input and replaces nothing")
    func uncertainAbsenceReplacesNothing() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.noteRecency(Fixture.event(12, .appeared, at: 10), members: members)
        core.noteRecency(Fixture.event(11, .appeared, at: 20), members: members)
        #expect(core.selected?.surface == Fixture.identity(11))

        let afterAbsence = folder.settle([12])
        core.reselect(members: afterAbsence)

        #expect(core.selected?.surface == Fixture.identity(11), "An absence proves nothing")
        #expect(core.suspensions.contains(.selectedSurfaceAbsent(Fixture.identity(11))))
        #expect(afterAbsence.count == 2, "The absent surface is still a member")
    }

    @Test("A visibility reading that decided nothing suspends without closing or replacing")
    func uncertainVisibilitySuspendsOnly() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.noteRecency(Fixture.event(12, .appeared, at: 10), members: members)
        core.noteRecency(Fixture.event(11, .appeared, at: 20), members: members)
        core.observeVisibility(Fixture.visibility(11, .uncertain), members: members)

        #expect(core.selected?.surface == Fixture.identity(11))
        #expect(core.ineligible[Fixture.identity(11)] == nil)
        #expect(core.suspensions.contains(.visibilityUncertain(Fixture.identity(11))))
    }

    // MARK: The observational boundary

    @Test("A to B to A is a new selection and never a revival of the first one")
    func returningToAnEarlierTargetIsANewGeneration() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)

        core.noteRecency(Fixture.event(11, .appeared, at: 10), members: members)
        let first = core.selected

        core.noteRecency(Fixture.event(12, .appeared, at: 20), members: members)
        core.noteRecency(Fixture.event(11, .returnedToFront, at: 30), members: members)
        let third = core.selected

        #expect(first?.surface == third?.surface)
        #expect(third?.generation == core.generation)
        #expect((third?.generation ?? 0) > (first?.generation ?? 0))
    }

    @Test("A Window ID that comes back carries no fact of the surface that had it")
    func aReusedWindowIdentifierStartsFromNothing() {

        var folder  = MemberFolder()
        let members = folder.settle([11, 12])
        var core    = Fixture.core(documents: [11, 12], members: members)
        core.noteRecency(Fixture.event(12, .appeared, at: 10), members: members)

        let survivors = folder.settle([11])
        core.forget(Fixture.identity(12), members: survivors)

        let returned = folder.settle([11, 12])
        core.reselect(members: returned)

        #expect(core.ineligible[Fixture.identity(12)] == .roleNotRead)
        #expect(core.recency.marks[Fixture.identity(12)] == nil)
        #expect(core.selected?.surface == Fixture.identity(11))
    }

    @Test("The end of the assignment gives the selection up and suspends")
    func endOfTheAssignmentClearsEverything() {

        var folder  = MemberFolder()
        let members = folder.settle([11])
        var core    = Fixture.core(documents: [11], members: members)
        let before  = core.generation

        core.endAssignment()

        #expect(core.selected == nil)
        #expect(core.generation > before)
        #expect(core.suspensions == [.notAssigned])
        #expect(core.candidates.isEmpty)
    }
}

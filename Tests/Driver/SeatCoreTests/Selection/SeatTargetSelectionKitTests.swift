//
//  SeatTargetSelectionKitTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// The selection composed with the assignment nucleus that was already
/// committed: one application is handed over, its surfaces are folded in through
/// `SeatAssignmentKit`, and the target is decided over the membership that kit
/// holds.
///
/// Nothing native happens. No window is opened, moved, raised or observed, no
/// Virtual Display exists and no input path is reachable from here. The suite
/// proves the composition and the gate, and it certifies no macOS capability.
@Suite("The selection composed with the assignment nucleus")
struct SeatTargetSelectionKitTests {

    typealias Fixture    = SelectionFixtures
    typealias Assignment = AssignmentFixtures

    static func composed(
        _ effector: any SurfaceEffecting = RecordingSurfaceEffector()
    ) -> (assignment: SeatAssignmentKit, selection: SeatTargetSelectionKit) {

        let assignment = SeatAssignmentKit(effector: effector)
        _ = assignment.handOver(
            instance   : Assignment.target,
            attestation: .windowServerAttested,
            at         : 0
        )
        return (assignment, SeatTargetSelectionKit(assignment: assignment))
    }

    @discardableResult
    static func ingest(
        _ selection    : SeatTargetSelectionKit,
        _ windowNumbers: [Int],
        frame          : CGRect = Assignment.contained,
        at now         : UInt64
    ) -> TargetSelectionStatus {

        selection.ingest(
            Assignment.reading(windowNumbers.map { Assignment.row($0, at: frame) }),
            within  : Assignment.virtual,
            displays: Assignment.displays,
            at      : now
        )
    }

    /// Declares the ordinary facts of a visible document, which every case here
    /// varies from.
    static func describeDocument(_ selection: SeatTargetSelectionKit, _ windowNumber: Int) {
        selection.declareRole(Fixture.role(windowNumber, .document))
        selection.observeVisibility(Fixture.visibility(windowNumber, .visibleInteractive))
    }

    // MARK: A sheet attached to one window

    @Test("A window-scoped modal names its host, blocks it, and owes no return of its own")
    func anAttachedSheetIsTheHostsBusiness() {

        let (assignment, selection) = Self.composed()
        Self.ingest(selection, [11, 12], at: 0)
        Self.ingest(selection, [11, 12], at: 10_000_000)

        Self.describeDocument(selection, 11)
        selection.declareRole(Fixture.role(12, .dialog))
        selection.observeVisibility(Fixture.visibility(12, .visibleInteractive))
        selection.declareParent(Fixture.parent(12, of: 11))
        selection.declareModal(Fixture.modal(12, over: 11))

        #expect(selection.attachedHost(of: Fixture.identity(12)) == Fixture.identity(11))
        #expect(selection.attachedHost(of: Fixture.identity(11)) == nil)
        #expect(selection.attachedModals == [Fixture.identity(12)])
        #expect(selection.isModallyBlocked(Fixture.identity(11)))
        #expect(!selection.isModallyBlocked(Fixture.identity(12)))
        #expect(selection.selected?.surface == Fixture.identity(12),
                "The sheet is what is usable while it is up")

        // The host is inside the seat and owes a return; the sheet is drawn in
        // it, goes where it goes, and is not a claim of its own.
        #expect(assignment.inventory.heldMembers.map(\.windowNumber) == [11])

        // An application-scoped modal is a window standing beside the others.
        let (beside, second) = Self.composed()
        Self.ingest(second, [11, 12], at: 0)
        Self.ingest(second, [11, 12], at: 10_000_000)
        Self.describeDocument(second, 11)
        second.declareRole(Fixture.role(12, .dialog))
        second.observeVisibility(Fixture.visibility(12, .visibleInteractive))
        second.declareModal(Fixture.modal(12, over: nil))

        #expect(second.attachedHost(of: Fixture.identity(12)) == nil)
        #expect(second.isModallyBlocked(Fixture.identity(11)))
        #expect(beside.inventory.heldMembers.map(\.windowNumber) == [11, 12])
    }

    // MARK: Selected, then operational

    @Test("A contained, unblocked and observed target is operational, and nothing less is")
    func operationalNeedsEverything() {

        let (_, selection) = Self.composed()
        Self.ingest(selection, [11], at: 0)
        let settled = Self.ingest(selection, [11], at: 10_000_000)

        #expect(settled.assignment?.containmentIsVerified == true)

        Self.describeDocument(selection, 11)
        let noted = selection.noteRecency(Fixture.event(11, .appeared, at: 10))

        #expect(noted == nil)
        #expect(selection.selected?.surface == Fixture.identity(11))

        let generation = selection.selectionGeneration
        let missing    = selection.operability()
        let ready      = selection.operability(
            observation: Fixture.observation(11, generation: generation)
        )
        let stale = selection.operability(
            observation: Fixture.observation(11, generation: generation, frame: Assignment.outside)
        )

        #expect(missing.causes == [.observationMissing])
        #expect(ready.isOperational)
        #expect(ready.target?.surface == Fixture.identity(11))
        #expect(stale.causes == [.observationGeometryStale(Fixture.identity(11))])
    }

    @Test("Selection and containment are separate: the target is chosen and the input still waits")
    func containmentIsAnIndependentCause() {

        let (_, selection) = Self.composed(UnqualifiedSurfaceEffector())
        Self.ingest(selection, [11], frame: Assignment.outside, at: 0)
        let settled = Self.ingest(selection, [11], frame: Assignment.outside, at: 10_000_000)

        Self.describeDocument(selection, 11)
        let generation = selection.selectionGeneration
        let gated      = selection.operability(
            observation: Fixture.observation(11, generation: generation, frame: Assignment.outside)
        )

        #expect(selection.selected?.surface == Fixture.identity(11), "Selected, on the policy alone")
        #expect(settled.assignment?.containmentIsVerified == false)
        #expect(gated.causes == [.containmentNotVerified(blocks: settled.assignment?.blocks ?? [])])
        #expect(!gated.isOperational, "No target is operational for being selected")
    }

    // MARK: The events the assignment nucleus produces are not recency

    @Test("The transfers the kit asks for are not appearances")
    func placementsIssuedByTheKitAreNotRecency() {

        let effector       = RecordingSurfaceEffector()
        let (_, selection) = Self.composed(effector)

        Self.ingest(selection, [11, 12], frame: Assignment.outside, at: 0)
        let requested = Self.ingest(selection, [11, 12], frame: Assignment.outside, at: 10_000_000)

        Self.describeDocument(selection, 11)
        Self.describeDocument(selection, 12)
        let status = selection.status()

        #expect(requested.assignment?.issuedMoves == [11, 12])
        #expect(effector.requestedWindowNumbers == [11, 12])
        #expect(selection.core.recency.marks.isEmpty, "A placement the kit asked for is not an event")
        #expect(status.selected == nil)
        #expect(status.operability.causes.contains(.explicitSelectionRequired(
            candidates: [Fixture.identity(11), Fixture.identity(12)]
        )))
    }

    @Test("The order of the members is Window ID order and never a chronology")
    func memberOrderIsNotChronology() {

        let (_, selection) = Self.composed()
        Self.ingest(selection, [11, 12], at: 0)
        Self.ingest(selection, [11, 12], at: 10_000_000)
        Self.describeDocument(selection, 11)
        Self.describeDocument(selection, 12)

        #expect(selection.selected == nil, "Two members in Window ID order are not an order")

        let noted = selection.noteRecency(Fixture.event(12, .appeared, at: 5))

        #expect(noted == nil)
        #expect(selection.selected?.surface == Fixture.identity(12))
    }

    // MARK: Closing a dialog, through the assignment nucleus

    @Test("A confirmed closure returns to the parent, and an absence confirms nothing")
    func confirmedClosureReturnsToTheParent() {

        let (_, selection) = Self.composed()
        Self.ingest(selection, [11, 12], at: 0)
        Self.ingest(selection, [11, 12], at: 10_000_000)

        Self.describeDocument(selection, 11)
        selection.declareRole(Fixture.role(12, .dialog))
        selection.observeVisibility(Fixture.visibility(12, .visibleInteractive))
        selection.declareParent(Fixture.parent(12, of: 11))
        selection.declareModal(Fixture.modal(12, over: 11))
        selection.noteRecency(Fixture.event(11, .appeared, at: 10))
        selection.noteRecency(Fixture.event(12, .appeared, at: 20))

        #expect(selection.selected?.surface == Fixture.identity(12))

        let absent = selection.confirmClosure(of: 12, evidence: .absentFromReading)

        #expect(absent.selected?.surface == Fixture.identity(12), "An absence is not a closure")

        let closed = selection.confirmClosure(of: 12, evidence: .windowServerConfirmedDestruction)

        #expect(closed.selected?.surface == Fixture.identity(11))
        #expect(closed.selected?.reason == .returnToParent)
        #expect(closed.candidates == [Fixture.identity(11)])
    }

    // MARK: The observational boundary

    @Test("An observation of an earlier selection is refused after A to B to A")
    func observationOfAnEarlierSelectionIsRefused() {

        let (_, selection) = Self.composed()
        Self.ingest(selection, [11, 12], at: 0)
        Self.ingest(selection, [11, 12], at: 10_000_000)
        Self.describeDocument(selection, 11)
        Self.describeDocument(selection, 12)

        selection.noteRecency(Fixture.event(11, .appeared, at: 10))
        let first = selection.selectionGeneration

        selection.noteRecency(Fixture.event(12, .appeared, at: 20))
        selection.noteRecency(Fixture.event(11, .returnedToFront, at: 30))
        let current = selection.selectionGeneration

        let late = selection.operability(observation: Fixture.observation(11, generation: first))

        #expect(selection.selected?.surface == Fixture.identity(11))
        #expect(late.causes == [.observationSuperseded(observed: first, current: current)])
        #expect(!late.isOperational)
    }

    // MARK: The end of the assignment

    @Test("An assignment given back takes the selection with it")
    func releaseEndsTheSelection() {

        let (assignment, selection) = Self.composed()
        Self.ingest(selection, [11], at: 0)
        Self.ingest(selection, [11], at: 10_000_000)
        Self.describeDocument(selection, 11)

        #expect(selection.selected?.surface == Fixture.identity(11))

        _ = assignment.release()
        let status = selection.status()

        #expect(status.selected == nil)
        #expect(status.operability == .suspended(target: nil, causes: [.notAssigned]))
        #expect(status.candidates.isEmpty)
    }

    @Test("A second handover does not inherit the facts of the first assignment")
    func anotherAssignmentStartsFromNothing() {

        let (assignment, selection) = Self.composed()
        Self.ingest(selection, [11], at: 0)
        Self.ingest(selection, [11], at: 10_000_000)
        Self.describeDocument(selection, 11)
        _ = assignment.release()

        _ = assignment.handOver(
            instance   : Assignment.restart,
            attestation: .windowServerAttested,
            at         : 20_000_000
        )
        let status = selection.status()

        #expect(status.selected == nil)
        #expect(selection.core.facts.isEmpty)
        #expect(status.operability.causes.contains(.noEligibleTarget))
    }

    // MARK: Versioned readings

    @Test("Every change carries a newer revision")
    func revisionsMoveForward() {

        let (_, selection) = Self.composed()
        let first = Self.ingest(selection, [11], at: 0)
        let next  = Self.ingest(selection, [11], at: 10_000_000)

        #expect(next.revision > first.revision)
        #expect(selection.revision == next.revision)
    }
}

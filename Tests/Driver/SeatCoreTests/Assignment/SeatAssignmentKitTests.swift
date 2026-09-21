//
//  SeatAssignmentKitTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// The whole internal nucleus, composed and driven end to end: an application is
/// handed over, its surfaces are folded in from written readings, the transfers
/// are asked of a controlled adapter, and the windows are given back.
///
/// Nothing native happens. The suite proves the algorithms and the composition;
/// it proves nothing about helper parentage, inventory completeness, Qt windows
/// or focus on a real system, all of which need their own qualified evidence.
@Suite("The assignment nucleus, composed")
struct SeatAssignmentKitTests {

    typealias Fixture = AssignmentFixtures

    static func handedOver(
        _ effector: any SurfaceEffecting = RecordingSurfaceEffector()
    ) -> SeatAssignmentKit {

        let kit = SeatAssignmentKit(effector: effector)
        _ = kit.handOver(instance: Fixture.target, attestation: .windowServerAttested, at: 0)
        return kit
    }

    @discardableResult
    static func ingest(
        _ kit    : SeatAssignmentKit,
        _ rows   : [SurfaceInventoryReading.Row],
        claims   : [HelperRelationClaim] = [],
        at now   : UInt64
    ) -> AssignmentStatus {

        kit.ingest(
            Fixture.reading(rows),
            claims              : claims,
            within              : Fixture.virtual,
            displays            : Fixture.displays,
            at                  : now
        )
    }

    // MARK: The handover contains the windows that were already open

    @Test("A pre-existing window is transferred, and the set is contained once it is verified there")
    func handoverContainsPreexistingWindows() {
        let effector = RecordingSurfaceEffector()
        let kit      = Self.handedOver(effector)

        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)
        let requested = Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 10_000_000)

        #expect(effector.requests == [
            .init(identity: Fixture.identity(11), frame: Fixture.contained),
        ])
        #expect(requested.issuedMoves == [11])
        #expect(!requested.containmentIsVerified)

        Self.ingest(kit, [Fixture.row(11, at: Fixture.contained)], at: 20_000_000)
        let settled = Self.ingest(kit, [Fixture.row(11, at: Fixture.contained)], at: 30_000_000)

        #expect(settled.containmentIsVerified)
        #expect(settled.blocks.isEmpty)
        #expect(effector.requests.count == 1, "One logical attempt, and the window stayed put")
        #expect(kit.inventory.members.first?.origin == .preexisting)
    }

    @Test("A window already entirely inside the seat enters management with no move at all")
    func alreadyVirtualWindowIsNotMoved() {
        let effector = RecordingSurfaceEffector()
        let kit      = Self.handedOver(effector)

        Self.ingest(kit, [Fixture.row(11, at: Fixture.contained)], at: 0)
        let settled = Self.ingest(kit, [Fixture.row(11, at: Fixture.contained)], at: 10_000_000)

        #expect(effector.requests.isEmpty)
        #expect(settled.containmentIsVerified)
        #expect(kit.inventory.containedMembers.map(\.windowNumber) == [11])
    }

    // MARK: An unqualified adapter refuses, with a reason

    @Test("The shipped effector refuses every effect and the set is never contained")
    func unqualifiedEffectorRefusesWithAReason() {
        let kit = Self.handedOver(UnqualifiedSurfaceEffector())

        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)
        let refused = Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 10_000_000)

        #expect(!kit.effectorQualification.mayAct)
        #expect(refused.issuedMoves.isEmpty)
        #expect(refused.blocks.contains(.effectRefused(
            windowNumber: 11,
            refusal     : .adapterNotQualified(reason: UnqualifiedSurfaceEffector.defaultReason)
        )))
        #expect(!refused.containmentIsVerified)
    }

    @Test("A refusal is not retried by the next reading")
    func aRefusalIsNotRetried() {
        let effector = RecordingSurfaceEffector(
            refusals: [11: .destinationUnusable(reason: "the double refuses this one")]
        )
        let kit = Self.handedOver(effector)

        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)
        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 10_000_000)
        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 20_000_000)

        #expect(effector.requests.count == 1)

        effector.refusals = [:]
        kit.rearmContainment()
        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 30_000_000)

        #expect(effector.requests.count == 2, "Only an explicit rearm offers the surface again")
    }

    // MARK: Helpers, and the doubt that suspends everything

    @Test("A shared service gives up the named surface only, and the unnamed one suspends the set")
    func sharedServiceSurfaceOnly() {
        let effector = RecordingSurfaceEffector()
        let kit      = Self.handedOver(effector)
        let claims   = [
            HelperRelationClaim(
                surface   : Fixture.identity(41, of: Fixture.helper),
                serves    : Fixture.target,
                relation  : .sharedServiceSurface(windowNumber: 41),
                provenance: .helperRelationAttestation
            ),
        ]
        let rows = [
            Fixture.row(11, at: Fixture.contained),
            Fixture.row(41, at: Fixture.outside, of: Fixture.helper),
            Fixture.row(42, at: Fixture.outside, of: Fixture.helper),
        ]

        Self.ingest(kit, rows, claims: claims, at: 0)
        let settled = Self.ingest(kit, rows, claims: claims, at: 10_000_000)

        #expect(effector.requestedWindowNumbers == [41])
        #expect(settled.blocks.contains(
            .attributionUncertain(windowNumber: 42, doubt: .sharedServiceSurfaceNotNamed)
        ))
        #expect(!settled.containmentIsVerified, "A doubt about one surface suspends the set")
        #expect(kit.inventory.surfaces[42] == nil)
    }

    // MARK: Readings that fail, and readings that are not whole

    @Test("A failed reading changes nothing and says so")
    func failedReadingChangesNothing() {
        let kit = Self.handedOver()
        Self.ingest(kit, [Fixture.row(11, at: Fixture.contained)], at: 0)
        Self.ingest(kit, [Fixture.row(11, at: Fixture.contained)], at: 10_000_000)

        let failed = kit.ingest(
            .unavailable(reason: "the window server read failed"),
            within: Fixture.virtual,
            at    : 20_000_000
        )

        #expect(failed.blocks == [.readingUnavailable(reason: "the window server read failed")])
        #expect(!failed.containmentIsVerified)
        #expect(kit.inventory.members.count == 1, "Nothing was folded in and nothing was forgotten")
    }

    @Test("A reading that cannot carry the whole application keeps the gate closed")
    func incompleteReadingKeepsTheGateClosed() {
        let kit = Self.handedOver()
        let row = Fixture.row(11, at: Fixture.contained)

        _ = kit.ingest(
            SurfaceInventoryReading(rows: [row], completeness: .complete(provenance: .onScreenWindowList)),
            within: Fixture.virtual,
            at    : 0
        )
        let settled = kit.ingest(
            SurfaceInventoryReading(rows: [row], completeness: .complete(provenance: .onScreenWindowList)),
            within: Fixture.virtual,
            at    : 10_000_000
        )

        #expect(!settled.containmentIsVerified)
        #expect(settled.blocks.count == 1)
    }

    // MARK: The assignment outlives its windows

    @Test("An application with no windows stays assigned and contained")
    func zeroWindowsKeepsTheAssignment() {
        let kit = Self.handedOver()
        let empty = Self.ingest(kit, [], at: 0)

        #expect(kit.lifecycle.isAssigned)
        #expect(empty.containmentIsVerified)

        // A window opened later belongs to the same assignment.
        Self.ingest(kit, [Fixture.row(12, at: Fixture.contained)], at: 10_000_000)
        let settled = Self.ingest(kit, [Fixture.row(12, at: Fixture.contained)], at: 20_000_000)

        #expect(kit.inventory.surfaces[12]?.origin == .bornDuringAssignment)
        #expect(settled.containmentIsVerified)
    }

    @Test("A window of the same PID from a later lifetime is not taken into the seat")
    func reusedProcessIdentifierIsNotAdopted() {
        let effector = RecordingSurfaceEffector()
        let kit      = Self.handedOver(effector)

        Self.ingest(kit, [Fixture.row(21, at: Fixture.outside, of: Fixture.restart)], at: 0)
        Self.ingest(kit, [Fixture.row(21, at: Fixture.outside, of: Fixture.restart)], at: 10_000_000)

        #expect(kit.inventory.members.isEmpty)
        #expect(effector.requests.isEmpty)
    }

    @Test("Without an assignment nothing is folded and nothing is asked for")
    func nothingIsDoneWithoutAnAssignment() {
        let effector = RecordingSurfaceEffector()
        let kit      = SeatAssignmentKit(effector: effector)

        let status = Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)

        #expect(status.blocks == [.notAssigned])
        #expect(effector.requests.isEmpty)
        #expect(kit.inventory.members.isEmpty)
    }

    // MARK: Focus, during a containment that is not finished

    @Test("The focus may be restored while surfaces the seat is sure about are still to be moved")
    func focusMayPrecedeFullContainment() {
        let kit = Self.handedOver()
        let pending = Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)
        let destination = Fixture.identity(900, of: Fixture.stranger)

        kit.prepareFocus(
            FocusPreparation(destination: destination, isAttested: true, startedAtNanoseconds: 0)
        )
        let decision = kit.decideFocusAttempt(
            at                 : 1_000_000,
            userIntentPrevails : false,
            topologyIsUnchanged: true
        )

        #expect(!pending.containmentIsVerified)
        #expect(decision == .mayRequest(destination: destination))

        // The exception covers the focus request and nothing else.
        kit.noteFocusRequest(
            destination           : destination,
            restoreCallNanoseconds: 4_000_000,
            returnedAt            : 2_000_000
        )
        #expect(kit.observeFocus(frontmost: destination, at: 2_100_000) == .pending)
        #expect(kit.observeFocus(frontmost: destination, at: 2_200_000) == .verified)
        #expect(!Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 10_000_000)
            .containmentIsVerified)
    }

    // MARK: Giving the application back

    @Test("A release with no valid destination revokes input, stays incomplete and keeps the display")
    func releaseWithoutDestinationIsIncomplete() {
        let effector = RecordingSurfaceEffector()
        let kit      = Self.handedOver(effector)

        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)
        Self.ingest(
            kit,
            [Fixture.row(11, at: Fixture.outside), Fixture.row(12, at: Fixture.contained)],
            at: 10_000_000
        )

        let outcome = kit.release(chosenDisplays: [:], displays: [:])

        #expect(outcome.inputAuthorityIsRevoked)
        #expect(!outcome.isComplete)
        #expect(outcome.retainsVirtualDisplay)
        #expect(outcome.issuedReturns.isEmpty)
        #expect(outcome.blocks == [
            .originalPlaceGone(windowNumber: 11),
            .noDestinationChosen(windowNumber: 12),
        ])
        #expect(!kit.lifecycle.isAssigned)
    }

    @Test("The consumer chooses a destination later, and two readings confirm the return")
    func restitutionCompletesWhenTheConsumerChooses() {
        let effector = RecordingSurfaceEffector()
        let kit      = Self.handedOver(effector)

        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)
        Self.ingest(
            kit,
            [Fixture.row(11, at: Fixture.outside), Fixture.row(12, at: Fixture.contained)],
            at: 10_000_000
        )
        _ = kit.release()

        let chosen = kit.completeRestitution(
            chosenDisplays: [12: Fixture.physicalDisplayID],
            displays      : Fixture.displays
        )

        #expect(chosen.blocks.isEmpty)
        #expect(chosen.issuedReturns.map(\.destinationFrame) == [
            Fixture.outside,
            CGRect(x: 560, y: 240, width: 800, height: 600),
        ])
        #expect(chosen.retainsVirtualDisplay, "Delivery is not proof that the windows are back")

        let observations = [11: Fixture.outside, 12: CGRect(x: 560, y: 240, width: 800, height: 600)]
        #expect(kit.confirmReturns(observations: observations).isEmpty)
        #expect(kit.confirmReturns(observations: observations) == [11, 12])
        #expect(kit.completeRestitution().isComplete)
    }

    @Test("Releasing what was never assigned is a rejection before any effect")
    func releasingNothingIsARejection() {
        let effector = RecordingSurfaceEffector()
        let outcome  = SeatAssignmentKit(effector: effector).release()

        #expect(outcome.blocks == [.notAssigned])
        #expect(outcome.issuedReturns.isEmpty)
        #expect(!outcome.retainsVirtualDisplay)
        #expect(effector.requests.isEmpty)
    }

    @Test("Stopping the seat gives the windows back and refuses every later handover")
    func stoppingTheSeatEndsEverything() {
        let kit = Self.handedOver()
        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)

        let outcome = kit.stopSeat(displays: Fixture.displays)

        #expect(outcome.inputAuthorityIsRevoked)
        #expect(outcome.issuedReturns.map(\.windowNumber) == [11])
        #expect(
            kit.handOver(instance: Fixture.restart, attestation: .windowServerAttested, at: 99)
                == .failure(.seatStopped)
        )
    }

    @Test("The exit of the instance ends the assignment with nothing to give back")
    func exitEndsTheAssignment() {
        let effector = RecordingSurfaceEffector()
        let kit      = Self.handedOver(effector)
        Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)

        #expect(kit.noteExit(of: Fixture.target)?.instance == Fixture.target)
        #expect(!kit.lifecycle.isAssigned)
        #expect(kit.inventory.members.isEmpty)
        #expect(effector.requests.isEmpty)
    }

    // MARK: A revisioned reading of the state

    @Test("Every change carries a newer revision")
    func revisionsMoveForward() {
        let kit   = Self.handedOver()
        let first = Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 0)
        let next  = Self.ingest(kit, [Fixture.row(11, at: Fixture.outside)], at: 10_000_000)

        #expect(next.revision > first.revision)
        #expect(kit.revision == next.revision)
    }
}

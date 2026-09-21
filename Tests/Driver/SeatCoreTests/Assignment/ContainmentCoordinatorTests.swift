//
//  ContainmentCoordinatorTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// What the seat may ask for, and every reason it may not, decided from folded
/// readings and clock values that are written down. Nothing is moved: the plan
/// is a request and the suites check the request.
@Suite("Coordinating the containment of an assigned application")
struct ContainmentCoordinatorTests {

    typealias Fixture = AssignmentFixtures

    static let attributor = SurfaceAttributor(instance: Fixture.target)

    /// Folds the readings into a real inventory, so every member a plan is made
    /// from came through the same membership logic the kit composes.
    static func inventory(
        _ readings: [SurfaceInventoryReading],
        step      : UInt64 = 10_000_000
    ) -> AssignedSurfaceInventory {

        var inventory = AssignedSurfaceInventory()
        for (index, reading) in readings.enumerated() {
            inventory.fold(
                reading,
                attributor: attributor,
                within    : Fixture.virtual,
                displays  : Fixture.displays,
                at        : UInt64(index) &* step,
                isHandover: index == 0
            )
        }
        return inventory
    }

    static func plan(
        _ coordinator: ContainmentCoordinator,
        _ inventory  : AssignedSurfaceInventory,
        at now       : UInt64 = 20_000_000
    ) -> ContainmentPlan {

        coordinator.plan(
            members      : inventory.members,
            uncertain    : inventory.uncertain,
            completeness : inventory.completeness,
            virtualBounds: Fixture.virtual,
            at           : now
        )
    }

    static func coordinator() -> ContainmentCoordinator {
        ContainmentCoordinator(handoverStartedAtNanoseconds: 0)
    }

    static let twiceOutside = [
        Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
        Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
    ]

    // MARK: The baseline is not an exemption

    @Test("A window the handover found outside the seat is planned for a transfer")
    func preexistingWindowIsTransferred() {
        let plan = Self.plan(Self.coordinator(), Self.inventory(Self.twiceOutside))

        #expect(plan.moves == [
            SurfaceMove(identity: Fixture.identity(11), destinationFrame: Fixture.contained),
        ])
        #expect(plan.blocks == [.surfaceOutsideSeat(windowNumber: 11)])
        #expect(!plan.isContained)
    }

    @Test("A window already entirely inside the seat is taken in where it stands")
    func alreadyVirtualSurfaceIsNotMoved() {
        let plan = Self.plan(Self.coordinator(), Self.inventory([
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
        ]))

        #expect(plan.moves.isEmpty)
        #expect(plan.blocks.isEmpty)
        #expect(plan.isContained)
    }

    @Test("A single sighting is not moved and is reported as unverified")
    func singleSightingIsNotMoved() {
        let plan = Self.plan(
            Self.coordinator(),
            Self.inventory([Fixture.reading([Fixture.row(11, at: Fixture.outside)])])
        )

        #expect(plan.moves.isEmpty)
        #expect(plan.blocks == [
            .surfaceOutsideSeat(windowNumber: 11),
            .surfaceUnverified(windowNumber: 11),
        ])
    }

    // MARK: Zero windows, and an application that is still assigned

    @Test("An application with no windows is contained, which ends nothing")
    func zeroWindowsIsContained() {
        let plan = Self.plan(Self.coordinator(), Self.inventory([Fixture.reading([])]))

        #expect(plan.moves.isEmpty)
        #expect(plan.blocks.isEmpty)
        #expect(plan.isContained)
    }

    // MARK: Doubts and incomplete readings close the gate

    @Test("An uncertain surface suspends the set, even when every member is contained")
    func uncertainSurfaceSuspendsTheWholeSet() {
        let contained = Fixture.row(11, at: Fixture.contained)
        let plan = Self.plan(Self.coordinator(), Self.inventory([
            Fixture.reading([contained]),
            Fixture.reading([contained, Fixture.unattestedRow(12, at: Fixture.outside)]),
        ]))

        #expect(plan.moves.isEmpty)
        #expect(plan.blocks == [
            .attributionUncertain(windowNumber: 12, doubt: .identityNotAttested),
        ])
        #expect(!plan.isContained)
    }

    @Test("A reading that cannot carry the whole application closes the gate")
    func incompleteInventoryClosesTheGate() {
        let row  = Fixture.row(11, at: Fixture.contained)
        let plan = Self.plan(Self.coordinator(), Self.inventory([
            Fixture.reading([row], completeness: .complete(provenance: .allWindowList)),
            Fixture.reading([row], completeness: .complete(provenance: .allWindowList)),
        ]))

        #expect(!plan.isContained)
        #expect(plan.blocks.count == 1)
        if case .inventoryNotQualified = plan.blocks[0] {} else {
            Issue.record("Expected the reading's provenance to be reported, got \(plan.blocks)")
        }
    }

    @Test("A member missing from the reading cannot be claimed contained")
    func absentMemberBlocksContainment() {
        let plan = Self.plan(Self.coordinator(), Self.inventory([
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            Fixture.reading([]),
        ]))

        #expect(plan.blocks.contains(.surfaceAbsent(windowNumber: 11)))
        #expect(!plan.isContained)
    }

    // MARK: One logical attempt per surface per episode

    @Test("A transfer that was asked for is not asked for again in the same episode")
    func oneAttemptPerSurface() {
        var coordinator = Self.coordinator()
        let inventory   = Self.inventory(Self.twiceOutside)

        #expect(Self.plan(coordinator, inventory).moves.count == 1)
        coordinator.noteMoveIssued(11)

        let second = Self.plan(coordinator, inventory)
        #expect(second.moves.isEmpty)
        #expect(second.blocks.contains(.attemptSpent(windowNumber: 11)))
        #expect(coordinator.issuedMoves == [11])
    }

    @Test("A refusal spends the attempt and is reported with its reason")
    func refusalSpendsTheAttempt() {
        var coordinator = Self.coordinator()
        let inventory   = Self.inventory(Self.twiceOutside)
        let refusal     = EffectRefusal.adapterNotQualified(reason: "nothing is qualified here")

        coordinator.noteMoveRefused(11, refusal)
        let plan = Self.plan(coordinator, inventory)

        #expect(plan.moves.isEmpty)
        #expect(plan.blocks.contains(.effectRefused(windowNumber: 11, refusal: refusal)))
        #expect(coordinator.issuedMoves.isEmpty)
    }

    @Test("Only an explicit rearm offers the surface again, and it keeps the deadline")
    func rearmIsExplicit() {
        var coordinator = Self.coordinator()
        let inventory   = Self.inventory(Self.twiceOutside)

        coordinator.noteMoveRefused(11, .identityNotAttested)
        coordinator.rearm()

        #expect(coordinator.episode == 2)
        #expect(Self.plan(coordinator, inventory).moves.count == 1)
        #expect(coordinator.handoverStartedAtNanoseconds == 0)
    }

    // MARK: Deadlines are reported, and report their elapsed time

    @Test("A surface not contained 250 ms after it was first seen is an explicit timeout")
    func surfaceDeadlineIsReported() {
        var coordinator = Self.coordinator()
        let inventory   = Self.inventory(Self.twiceOutside)
        coordinator.noteMoveIssued(11)

        let plan = Self.plan(coordinator, inventory, at: 300_000_000)

        #expect(plan.blocks.contains(
            .surfaceDeadlineExpired(windowNumber: 11, elapsedNanoseconds: 300_000_000)
        ))
        #expect(coordinator.issuedMoves == [11], "A timeout does not undo the transfer already asked for")
    }

    @Test("A handover not complete after 2 s is an explicit timeout too")
    func handoverDeadlineIsReported() {
        let plan = Self.plan(
            Self.coordinator(),
            Self.inventory(Self.twiceOutside),
            at: 2_500_000_000
        )

        #expect(plan.blocks.contains(
            .handoverDeadlineExpired(elapsedNanoseconds: 2_500_000_000)
        ))
    }

    @Test("A set contained in time reports no deadline at all")
    func containedSetReportsNoDeadline() {
        let plan = Self.plan(
            Self.coordinator(),
            Self.inventory([
                Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
                Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            ]),
            at: 9_000_000_000
        )

        #expect(plan.blocks.isEmpty)
        #expect(plan.isContained)
    }

    // MARK: The destination

    @Test("The destination keeps the window's size and centres it in the seat")
    func destinationPreservesTheSize() {
        let wide  = CGRect(x: 0, y: 0, width: 4_000, height: 3_000)
        let frame = SurfacePlacement.visibleFrame(forSizeOf: wide, on: Fixture.virtual)

        #expect(frame == Fixture.virtual)
        #expect(SurfacePlacement.visibleFrame(forSizeOf: Fixture.outside, on: Fixture.virtual)
            == Fixture.contained)
        #expect(SurfacePlacement.visibleFrame(forSizeOf: Fixture.outside, on: .null) == nil)
    }
}

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

    // MARK: The budgets count trustworthy time only

    static func hasSurfaceExpiry(_ blocks: [ContainmentBlock]) -> Bool {
        blocks.contains { if case .surfaceDeadlineExpired = $0 { true } else { false } }
    }

    static func hasHandoverExpiry(_ blocks: [ContainmentBlock]) -> Bool {
        blocks.contains { if case .handoverDeadlineExpired = $0 { true } else { false } }
    }

    static func hasUnqualifiedInventory(_ blocks: [ContainmentBlock]) -> Bool {
        blocks.contains { if case .inventoryNotQualified = $0 { true } else { false } }
    }

    /// Folds the readings and notes each pass on the coordinator's clock in the
    /// order `SeatAssignmentKit.ingest` does it, so a suite exercises the pair
    /// and not one half of it.
    static func runPasses(
        _ coordinator: inout ContainmentCoordinator,
        _ readings   : [SurfaceInventoryReading],
        step         : UInt64 = 10_000_000
    ) -> AssignedSurfaceInventory {

        var inventory = AssignedSurfaceInventory()
        for (index, reading) in readings.enumerated() {
            let now = UInt64(index) &* step
            coordinator.notePass(completeness: reading.completeness, at: now)
            inventory.fold(
                reading,
                attributor: attributor,
                within    : Fixture.virtual,
                displays  : Fixture.displays,
                at        : now,
                isHandover: index == 0
            )
            coordinator.noteSurfaces(inventory.members)
        }
        return inventory
    }

    /// The readings at their own instants, which is what a surface born in the
    /// middle of an assignment needs: the default step would put every pass
    /// 10 ms apart and an outage cannot be written down that way.
    static func runPasses(
        _ coordinator: inout ContainmentCoordinator,
        _ readings   : [(UInt64, SurfaceInventoryReading)]
    ) -> AssignedSurfaceInventory {

        var inventory = AssignedSurfaceInventory()
        for (index, pass) in readings.enumerated() {
            coordinator.notePass(completeness: pass.1.completeness, at: pass.0)
            inventory.fold(
                pass.1,
                attributor: attributor,
                within    : Fixture.virtual,
                displays  : Fixture.displays,
                at        : pass.0,
                isHandover: index == 0
            )
            coordinator.noteSurfaces(inventory.members)
        }
        return inventory
    }

    /// Two agreeing readings that contain the surface, then one that does not
    /// carry it. The absent pass is the one whose completeness a suite varies.
    static func absenceReadings(completeness: InventoryCompleteness) -> [SurfaceInventoryReading] {
        [
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            Fixture.reading([], completeness: completeness),
        ]
    }

    @Test("An absence nobody could read does not spend the surface budget")
    func unreadableAbsenceSpendsNoSurfaceBudget() {
        var coordinator = Self.coordinator()
        let inventory   = Self.runPasses(&coordinator, Self.absenceReadings(
            completeness: .incomplete(reason: "The native cross-check was unavailable")
        ))
        // The unreadable stretch runs from the third pass at 20 ms to the plan
        // at 600 ms, which is 580 ms of the 600 ms the wall clock shows.
        coordinator.notePass(
            completeness: .incomplete(reason: "The native cross-check was unavailable"),
            at          : 600_000_000
        )
        let plan = Self.plan(coordinator, inventory, at: 600_000_000)

        #expect(coordinator.unreadableNanoseconds == 580_000_000)
        #expect(plan.blocks.contains(.surfaceAbsent(windowNumber: 11)))
        #expect(!Self.hasSurfaceExpiry(plan.blocks))
    }

    @Test("An absence from a reading that succeeded spends it at the usual rate")
    func trustworthyAbsenceSpendsTheSurfaceBudget() {
        var coordinator = Self.coordinator()
        let inventory   = Self.runPasses(&coordinator, Self.absenceReadings(
            completeness: .complete(provenance: .qualifiedSurfaceEnumeration)
        ))
        let plan = Self.plan(coordinator, inventory, at: 600_000_000)

        #expect(coordinator.unreadableNanoseconds == 0)
        #expect(plan.blocks.contains(.surfaceAbsent(windowNumber: 11)))
        #expect(plan.blocks.contains(
            .surfaceDeadlineExpired(windowNumber: 11, elapsedNanoseconds: 600_000_000)
        ))
    }

    @Test("Once a reading can be trusted again the surface gives up promptly")
    func readableTimeAfterAnOutageStillExpires() {
        var coordinator = Self.coordinator()
        let inventory   = Self.runPasses(&coordinator, Self.absenceReadings(
            completeness: .incomplete(reason: "The native cross-check was unavailable")
        ))
        // 9.98 s of unreadable world from the third pass at 20 ms, then a
        // qualified one: the surface keeps the 20 ms it had spent and no more.
        coordinator.notePass(
            completeness: .complete(provenance: .qualifiedSurfaceEnumeration),
            at          : 10_000_000_000
        )
        let inTime = Self.plan(coordinator, inventory, at: 10_200_000_000)
        let late   = Self.plan(coordinator, inventory, at: 10_300_000_000)

        #expect(coordinator.unreadableNanoseconds == 9_980_000_000)
        #expect(!Self.hasSurfaceExpiry(inTime.blocks))
        #expect(late.blocks.contains(
            .surfaceDeadlineExpired(windowNumber: 11, elapsedNanoseconds: 320_000_000)
        ))
    }

    @Test("The handover budget is net of the unreadable time too")
    func handoverBudgetIsNetOfUnreadableTime() {
        var coordinator = Self.coordinator()
        let inventory   = Self.runPasses(&coordinator, [
            Fixture.reading(
                [Fixture.row(11, at: Fixture.outside)],
                completeness: .incomplete(reason: "The native cross-check was unavailable")
            ),
        ])
        coordinator.notePass(
            completeness: .incomplete(reason: "The native cross-check was unavailable"),
            at          : 23_000_000_000
        )
        let plan = Self.plan(coordinator, inventory, at: 23_000_000_000)

        #expect(coordinator.unreadableNanoseconds == 23_000_000_000)
        #expect(!Self.hasHandoverExpiry(plan.blocks))
    }

    @Test("A rearm keeps the unreadable account, like the deadlines it belongs to")
    func rearmKeepsTheUnreadableAccount() {
        var coordinator = Self.coordinator()
        coordinator.notePass(
            completeness: .unavailable(reason: "The window server fallback list could not be read"),
            at          : 100_000_000
        )
        coordinator.notePass(
            completeness: .complete(provenance: .qualifiedSurfaceEnumeration),
            at          : 400_000_000
        )
        let spent = coordinator.unreadableNanoseconds
        coordinator.rearm()

        #expect(spent == 400_000_000, "The handover instant seeds an account nothing has read yet")
        #expect(coordinator.unreadableNanoseconds == spent)
    }

    @Test("An unreadable pass makes nothing contained, verified or a member")
    func unreadableTimeGrantsNothing() {
        var coordinator = Self.coordinator()
        let inventory   = Self.runPasses(&coordinator, [
            Fixture.reading(
                [Fixture.row(11, at: Fixture.outside)],
                completeness: .incomplete(reason: "The native cross-check was unavailable")
            ),
            Fixture.reading(
                [Fixture.row(11, at: Fixture.outside)],
                completeness: .incomplete(reason: "The native cross-check was unavailable")
            ),
        ])
        let plan = Self.plan(coordinator, inventory, at: 5_000_000_000)

        #expect(!plan.isContained)
        #expect(inventory.containedMembers.isEmpty)
        #expect(inventory.members.allSatisfy { $0.presence == .outsideSeat })
        #expect(Self.hasUnqualifiedInventory(plan.blocks))
    }

    // MARK: A surface is charged only the outages of its own life

    static let outage = InventoryCompleteness.incomplete(
        reason: "The native cross-check was unavailable"
    )

    static let qualified = InventoryCompleteness.complete(
        provenance: .qualifiedSurfaceEnumeration
    )

    /// The host alone, then ten seconds nobody could read, then the dialog.
    /// The last pass is the one that gives window 12 two sightings, so it is a
    /// verified member outside the seat by the time any plan is made.
    static func dialogBornAfterAnOutage(
        _ coordinator: inout ContainmentCoordinator
    ) -> AssignedSurfaceInventory {

        let host   = Fixture.row(11, at: Fixture.contained)
        let dialog = Fixture.row(12, at: Fixture.outside)

        return runPasses(&coordinator, [
            (0,               Fixture.reading([host], completeness: qualified)),
            (10_000_000,      Fixture.reading([host], completeness: outage)),
            (10_010_000_000,  Fixture.reading([host], completeness: outage)),
            (10_020_000_000,  Fixture.reading([host, dialog], completeness: qualified)),
            (10_030_000_000,  Fixture.reading([host, dialog], completeness: qualified)),
        ])
    }

    @Test("a surface enters the pause account where it stands, not at zero")
    func aSurfaceEntersTheAccountWhereItStands() {
        var coordinator = Self.coordinator()
        _ = Self.dialogBornAfterAnOutage(&coordinator)

        #expect(coordinator.unreadableNanoseconds == 10_010_000_000)
        #expect(coordinator.entryPauseNanoseconds[11] == 0,
                "the host was there before the outage and lived through all of it")
        #expect(coordinator.entryPauseNanoseconds[12] == 10_010_000_000,
                "the dialog was born after it and owns none of it")
    }

    /// The defect: the account was subtracted whole from every surface, so a
    /// dialog born after a ten second outage started life with ten seconds of
    /// credit and could sit outside the seat for all of it in silence.
    @Test("a ten second outage before a dialog was born does not give it ten seconds")
    func anOutageBeforeBirthIsNotGifted() {
        var coordinator = Self.coordinator()
        let inventory   = Self.dialogBornAfterAnOutage(&coordinator)

        // 310 ms after the dialog appeared, all of it readable.
        let plan = Self.plan(coordinator, inventory, at: 10_330_000_000)

        #expect(plan.blocks.contains(
            .surfaceDeadlineExpired(windowNumber: 12, elapsedNanoseconds: 310_000_000)
        ))
        #expect(!plan.blocks.contains { block in
            if case .surfaceDeadlineExpired(11, _) = block { true } else { false }
        }, "the host is contained and is not waiting for anything")
    }

    @Test("an outage during the dialog's life spends only its own qualified budget")
    func anOutageDuringItsLifeIsItsOwn() {
        var coordinator = Self.coordinator()
        var inventory   = Self.dialogBornAfterAnOutage(&coordinator)

        let host   = Fixture.row(11, at: Fixture.contained)
        let dialog = Fixture.row(12, at: Fixture.outside)
        for (now, completeness) in [
            (10_040_000_000 as UInt64, Self.outage),
            (16_100_000_000 as UInt64, Self.outage),
        ] {
            coordinator.notePass(completeness: completeness, at: now)
            inventory.fold(
                Fixture.reading([host, dialog], completeness: completeness),
                attributor: Self.attributor,
                within    : Fixture.virtual,
                displays  : Fixture.displays,
                at        : now,
                isHandover: false
            )
            coordinator.noteSurfaces(inventory.members)
        }
        let plan = Self.plan(coordinator, inventory, at: 16_100_000_000)

        // 6.08 s of life, 6.06 s of it unreadable: 20 ms of budget spent.
        #expect(!Self.hasSurfaceExpiry(plan.blocks))
        #expect(plan.blocks.contains(.surfaceStalled(
            windowNumber        : 12,
            totalNanoseconds    : 6_080_000_000,
            qualifiedNanoseconds: 20_000_000
        )))
    }

    // MARK: An outage cannot suspend the goal for ever

    @Test("a wait the outage has held past its ceiling is reported with both times")
    func anEndlessOutageIsStalledAndNotSilent() {
        var coordinator = Self.coordinator()
        let inventory   = Self.runPasses(&coordinator, [
            Fixture.reading([Fixture.row(11, at: Fixture.outside)], completeness: Self.outage),
            Fixture.reading([Fixture.row(11, at: Fixture.outside)], completeness: Self.outage),
        ])
        coordinator.notePass(completeness: Self.outage, at: 23_000_000_000)
        let plan = Self.plan(coordinator, inventory, at: 23_000_000_000)

        #expect(coordinator.unreadableNanoseconds == 23_000_000_000)
        #expect(!Self.hasSurfaceExpiry(plan.blocks), "no qualified time passed at all")
        #expect(!Self.hasHandoverExpiry(plan.blocks))
        #expect(plan.blocks.contains(.surfaceStalled(
            windowNumber        : 11,
            totalNanoseconds    : 23_000_000_000,
            qualifiedNanoseconds: 0
        )))
        #expect(plan.blocks.contains(.handoverStalled(
            totalNanoseconds    : 23_000_000_000,
            qualifiedNanoseconds: 0
        )))
    }

    @Test("a stall is not reported for a wait the qualified budget already ended")
    func aSpentBudgetIsNotAlsoAStall() {
        var coordinator = Self.coordinator()
        let inventory   = Self.runPasses(&coordinator, Self.absenceReadings(
            completeness: Self.qualified
        ))
        let plan = Self.plan(coordinator, inventory, at: 23_000_000_000)

        #expect(plan.blocks.contains(
            .surfaceDeadlineExpired(windowNumber: 11, elapsedNanoseconds: 23_000_000_000)
        ))
        #expect(!plan.blocks.contains { block in
            if case .surfaceStalled = block { true } else { false }
        })
    }

    // MARK: A confirmed destruction ends the wait

    @Test("A destruction the window server confirmed drops the member and ends its wait")
    func confirmedDestructionEndsTheWait() {
        var coordinator = Self.coordinator()
        var inventory   = Self.runPasses(&coordinator, Self.absenceReadings(
            completeness: .complete(provenance: .qualifiedSurfaceEnumeration)
        ))
        let waiting = Self.plan(coordinator, inventory, at: 23_000_000_000)

        #expect(waiting.blocks.contains(.surfaceAbsent(windowNumber: 11)))
        #expect(waiting.blocks.contains(
            .surfaceDeadlineExpired(windowNumber: 11, elapsedNanoseconds: 23_000_000_000)
        ))

        let discarded = inventory.confirmClosure(
            of      : 11,
            evidence: .windowServerConfirmedDestruction
        )
        let ended = Self.plan(coordinator, inventory, at: 23_000_000_000)

        #expect(discarded)

        #expect(inventory.members.isEmpty)
        #expect(ended.blocks.isEmpty)
        #expect(ended.moves.isEmpty)
    }

    @Test("An absence offered as the same proof is refused and the wait stands")
    func absenceIsNotADestruction() {
        var coordinator = Self.coordinator()
        var inventory   = Self.runPasses(&coordinator, Self.absenceReadings(
            completeness: .complete(provenance: .qualifiedSurfaceEnumeration)
        ))

        let discarded = inventory.confirmClosure(of: 11, evidence: .absentFromReading)
        let plan      = Self.plan(coordinator, inventory, at: 23_000_000_000)

        #expect(!discarded)

        #expect(inventory.members.count == 1)
        #expect(plan.blocks.contains(.surfaceAbsent(windowNumber: 11)))
        #expect(!plan.isContained)
    }

    @Test("Ending a wait admits nothing: the surviving members keep their own evidence")
    func endingOneWaitGrantsTheOthersNothing() {
        var coordinator = Self.coordinator()
        var inventory   = Self.runPasses(&coordinator, [
            Fixture.reading([
                Fixture.row(11, at: Fixture.contained),
                Fixture.row(12, at: Fixture.outside),
            ]),
            Fixture.reading([Fixture.row(12, at: Fixture.outside)]),
        ])

        let discarded = inventory.confirmClosure(
            of      : 11,
            evidence: .windowServerConfirmedDestruction
        )
        let plan = Self.plan(coordinator, inventory, at: 30_000_000)

        #expect(discarded)

        #expect(!plan.isContained, "Window 12 is verified and still outside the seat")
        #expect(inventory.containedMembers.isEmpty)
        #expect(plan.blocks == [.surfaceOutsideSeat(windowNumber: 12)])
        #expect(plan.moves.count == 1, "It still has to be asked for, exactly as before")
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

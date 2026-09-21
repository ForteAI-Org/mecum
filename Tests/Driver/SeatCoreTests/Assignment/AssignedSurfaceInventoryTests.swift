//
//  AssignedSurfaceInventoryTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// Membership of an assigned application's surfaces, folded from readings that
/// are written down rather than taken. No window is created and no window server
/// is asked anything.
@Suite("The assigned surface inventory")
struct AssignedSurfaceInventoryTests {

    typealias Fixture = AssignmentFixtures

    static let attributor = SurfaceAttributor(instance: Fixture.target)

    /// Folds readings in one after another and answers the last batch of events.
    @discardableResult
    static func fold(
        _ inventory: inout AssignedSurfaceInventory,
        _ readings : [SurfaceInventoryReading],
        from       : UInt64 = 0,
        step       : UInt64 = 10_000_000,
        attributor : SurfaceAttributor = Self.attributor
    ) -> [SurfaceEvent] {

        var events: [SurfaceEvent] = []
        for (index, reading) in readings.enumerated() {
            events = inventory.fold(
                reading,
                attributor: attributor,
                within    : Fixture.virtual,
                displays  : Fixture.displays,
                at        : from &+ UInt64(index) &* step,
                isHandover: index == 0
            )
        }
        return events
    }

    // MARK: The handover reading is membership

    @Test("The windows the handover found are members, with the place they came from")
    func handoverRecordsPreexistingMembers() {
        var inventory = AssignedSurfaceInventory()
        Self.fold(&inventory, [Fixture.reading([Fixture.row(11, at: Fixture.outside)])])

        let member = inventory.members.first
        #expect(inventory.members.count == 1)
        #expect(member?.origin == .preexisting)
        #expect(member?.originalFrame == Fixture.outside)
        #expect(member?.originalDisplayID == Fixture.physicalDisplayID)
        #expect(member?.presence == .outsideSeat)
        #expect(member?.isVerified == false)
    }

    @Test("A window that appears later belongs to the assignment and was born in it")
    func laterWindowIsBornDuringAssignment() {
        var inventory = AssignedSurfaceInventory()
        Self.fold(&inventory, [
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([
                Fixture.row(11, at: Fixture.outside),
                Fixture.row(12, at: Fixture.contained),
            ]),
        ])

        #expect(inventory.surfaces[12]?.origin == .bornDuringAssignment)
        #expect(inventory.surfaces[12]?.presence == .containedInSeat)
    }

    @Test("A window already inside the seat has no physical display remembered")
    func alreadyVirtualSurfaceHasNoPhysicalOrigin() {
        var inventory = AssignedSurfaceInventory()
        Self.fold(&inventory, [Fixture.reading([Fixture.row(11, at: Fixture.contained)])])

        #expect(inventory.surfaces[11]?.originalDisplayID == nil)
        #expect(inventory.surfaces[11]?.presence == .containedInSeat)
    }

    // MARK: Two agreeing readings

    @Test("One sighting is not evidence; the second agreeing reading verifies it")
    func twoAgreeingReadingsVerify() {
        var inventory = AssignedSurfaceInventory()
        let events = Self.fold(&inventory, [
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
        ])

        #expect(events == [.verified(Fixture.surface(11, at: Fixture.outside).reference)])
        #expect(inventory.surfaces[11]?.isVerified == true)
        #expect(!inventory.hasUnverifiedSighting)
    }

    @Test("A frame that is still moving keeps the surface unverified")
    func disagreeingReadingsDoNotVerify() {
        var inventory = AssignedSurfaceInventory()
        let moving = CGRect(x: 300, y: 100, width: 800, height: 600)
        Self.fold(&inventory, [
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([Fixture.row(11, at: moving)]),
        ])

        #expect(inventory.surfaces[11]?.isVerified == false)
        #expect(inventory.hasUnverifiedSighting)
    }

    @Test("A verified member that leaves the seat is reported once it is agreed on")
    func leavingTheSeatIsReported() {
        var inventory = AssignedSurfaceInventory()
        let events = Self.fold(&inventory, [
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
        ])

        #expect(events.contains(.leftSeat(Fixture.surface(11, at: Fixture.outside).reference)))
    }

    // MARK: A failed reading is not an empty application

    @Test("A failed reading changes nothing at all")
    func failedReadingChangesNothing() {
        var inventory = AssignedSurfaceInventory()
        Self.fold(&inventory, [
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
        ])

        let events = inventory.fold(
            .unavailable(reason: "The window server read failed"),
            attributor: Self.attributor,
            within    : Fixture.virtual,
            at        : 999
        )

        #expect(events.isEmpty)
        #expect(inventory.members.count == 1)
        #expect(inventory.surfaces[11]?.isVerified == true)
        #expect(inventory.completeness.isQualified)
    }

    @Test("An incomplete reading keeps what it carried and stays unqualified")
    func incompleteReadingIsKept() {
        var inventory = AssignedSurfaceInventory()
        _ = inventory.fold(
            Fixture.reading(
                [Fixture.row(11, at: Fixture.outside)],
                completeness: .complete(provenance: .onScreenWindowList)
            ),
            attributor: Self.attributor,
            within    : Fixture.virtual,
            at        : 0,
            isHandover: true
        )

        #expect(inventory.members.count == 1)
        #expect(!inventory.completeness.isQualified)
        #expect(inventory.completeness.unqualifiedReason != nil)
    }

    // MARK: Absence, and what it does not prove

    @Test("A member missing from a reading keeps its membership and its reference")
    func absenceKeepsMembership() {
        var inventory = AssignedSurfaceInventory()
        let events = Self.fold(&inventory, [
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([]),
        ])

        #expect(events == [.absenceUncertain(windowNumber: 11)])
        #expect(inventory.surfaces[11]?.presence == .absentUncertain)
        #expect(inventory.surfaces[11]?.isVerified == false)
        #expect(inventory.surfaces[11]?.reference.frame == Fixture.outside)
    }

    @Test("A member that comes back has to be verified again")
    func returningMemberIsVerifiedAgain() {
        var inventory = AssignedSurfaceInventory()
        let events = Self.fold(&inventory, [
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([]),
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
        ])

        #expect(events == [.returnedFromAbsence(Fixture.surface(11, at: Fixture.outside).reference)])
        #expect(inventory.surfaces[11]?.isVerified == false)
    }

    @Test("An absence is refused as proof of closure")
    func absenceDoesNotProveClosure() {
        var inventory = AssignedSurfaceInventory()
        Self.fold(&inventory, [Fixture.reading([Fixture.row(11, at: Fixture.outside)])])

        // The answer is bound first because confirming mutates the inventory,
        // and the expectation would capture it as an immutable value.
        let refused = inventory.confirmClosure(of: 11, evidence: .absentFromReading)

        #expect(!refused)
        #expect(inventory.surfaces[11] != nil)
    }

    @Test("A confirmed closure discards the reference and a reused number starts over")
    func confirmedClosureInvalidatesTheReference() {
        var inventory = AssignedSurfaceInventory()
        Self.fold(&inventory, [
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
        ])

        let confirmed = inventory.confirmClosure(of: 11, evidence: .windowServerConfirmedDestruction)

        #expect(confirmed)
        #expect(inventory.surfaces[11] == nil)

        let events = inventory.fold(
            Fixture.reading([Fixture.row(11, at: Fixture.contained)]),
            attributor: Self.attributor,
            within    : Fixture.virtual,
            at        : 100
        )

        #expect(events == [
            .returnedAfterConfirmedClosure(Fixture.surface(11, at: Fixture.contained).reference),
        ])
        #expect(inventory.surfaces[11]?.isVerified == false)
        #expect(inventory.surfaces[11]?.origin == .bornDuringAssignment)
    }

    // MARK: Doubts are reported and never acted on

    @Test("A surface nobody could attribute is reported and is not a member")
    func uncertainSurfaceIsReportedNotAdopted() {
        var inventory = AssignedSurfaceInventory()
        let events = Self.fold(&inventory, [
            Fixture.reading([
                Fixture.row(11, at: Fixture.outside),
                Fixture.unattestedRow(12, at: Fixture.outside),
            ]),
        ])

        #expect(events.contains(.uncertainAttribution(windowNumber: 12, doubt: .identityNotAttested)))
        #expect(inventory.surfaces[12] == nil)
        #expect(inventory.uncertain[12] == .identityNotAttested)
    }

    @Test("An application with no windows keeps its membership empty and its reading qualified")
    func zeroWindowsIsNotAFailure() {
        var inventory = AssignedSurfaceInventory()
        Self.fold(&inventory, [Fixture.reading([])])

        #expect(inventory.members.isEmpty)
        #expect(inventory.completeness.isQualified)
    }
}

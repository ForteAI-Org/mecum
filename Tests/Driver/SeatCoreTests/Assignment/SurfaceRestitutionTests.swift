//
//  SurfaceRestitutionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// Where the windows go when the application is given back, and what happens
/// when there is nowhere valid for one of them to go. No window is moved and no
/// display is touched: the plan is checked, and the readings are written down.
@Suite("Giving the windows back")
struct SurfaceRestitutionTests {

    typealias Fixture = AssignmentFixtures

    /// The frame a window born in the seat takes on the person's main display
    /// once the consumer chooses it.
    static let onPhysical = CGRect(x: 560, y: 240, width: 800, height: 600)

    /// One pre-existing window on the person's display and one born in the seat.
    static func restitution() -> SurfaceRestitution {
        var inventory  = AssignedSurfaceInventory()
        let attributor = SurfaceAttributor(instance: Fixture.target)

        inventory.fold(
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            attributor: attributor,
            within    : Fixture.virtual,
            displays  : Fixture.displays,
            at        : 0,
            isHandover: true
        )
        inventory.fold(
            Fixture.reading([
                Fixture.row(11, at: Fixture.outside),
                Fixture.row(12, at: Fixture.contained),
            ]),
            attributor: attributor,
            within    : Fixture.virtual,
            displays  : Fixture.displays,
            at        : 10_000_000
        )

        var restitution = SurfaceRestitution()
        restitution.begin(members: inventory.members)
        return restitution
    }

    // MARK: The desktop travels with the obligation

    @Test("The desktop a window was on is carried into the pending return")
    func desktopIsCarriedIntoThePendingReturn() {
        var inventory = AssignedSurfaceInventory()
        inventory.fold(
            Fixture.reading([Fixture.row(11, at: Fixture.outside)]),
            attributor: SurfaceAttributor(instance: Fixture.target),
            within    : Fixture.virtual,
            displays  : Fixture.displays,
            spaceOf   : { _ in 2079 },
            at        : 0,
            isHandover: true
        )
        var restitution = SurfaceRestitution()
        restitution.begin(members: inventory.members)
        #expect(restitution.pending[11]?.originalSpaceID == 2079)
        #expect(Self.restitution().pending[11]?.originalSpaceID == nil)
    }

    // MARK: A pre-existing window goes back where it was

    @Test("A pre-existing window goes back to its original frame while that place is valid")
    func preexistingWindowGoesHome() {
        let plan = Self.restitution().plan(
            chosenDisplays: [12: Fixture.physicalDisplayID],
            displays      : Fixture.displays
        )

        #expect(plan.returns.contains(SurfaceReturn(
            identity        : Fixture.identity(11),
            origin          : .preexisting,
            destinationFrame: Fixture.outside
        )))
        #expect(plan.blocks.isEmpty)
    }

    @Test("A pre-existing window whose display is gone waits for the consumer to choose")
    func preexistingWindowWithoutItsDisplayWaits() {
        let plan = Self.restitution().plan(chosenDisplays: [:], displays: [:])

        #expect(plan.returns.isEmpty, "No window is placed on a display nobody chose")
        #expect(plan.blocks == [
            .originalPlaceGone(windowNumber: 11),
            .noDestinationChosen(windowNumber: 12),
        ])
    }

    @Test("A pre-existing window whose display is gone takes the display the consumer chose")
    func preexistingWindowTakesTheChosenDisplay() {
        let plan = Self.restitution().plan(
            chosenDisplays: [11: Fixture.laptopDisplayID],
            displays      : [Fixture.laptopDisplayID: Fixture.laptop]
        )

        #expect(plan.returns.contains(SurfaceReturn(
            identity        : Fixture.identity(11),
            origin          : .preexisting,
            destinationFrame: Fixture.onLaptop
        )))
    }

    // MARK: A window born in the seat needs a destination

    @Test("A window born during the assignment goes visibly onto the chosen display")
    func bornWindowGoesToTheChosenDisplay() {
        let plan = Self.restitution().plan(
            chosenDisplays: [12: Fixture.physicalDisplayID],
            displays      : Fixture.displays
        )

        #expect(plan.returns.contains(SurfaceReturn(
            identity        : Fixture.identity(12),
            origin          : .bornDuringAssignment,
            destinationFrame: Self.onPhysical
        )))
    }

    @Test("A chosen display that is not online is refused rather than replaced")
    func offlineChosenDisplayIsRefused() {
        let plan = Self.restitution().plan(
            chosenDisplays: [12: Fixture.laptopDisplayID],
            displays      : [Fixture.physicalDisplayID: Fixture.physical]
        )

        #expect(plan.blocks.contains(
            .chosenDisplayOffline(windowNumber: 12, displayID: Fixture.laptopDisplayID)
        ))
        #expect(plan.returns.map(\.windowNumber) == [11])
    }

    // MARK: A window is back when two readings say so

    @Test("One reading at the destination is not a return; the second agreeing one is")
    func twoAgreeingReadingsConfirmTheReturn() {
        var restitution = Self.restitution()
        restitution.noteIssued(11, destination: Fixture.outside)

        #expect(restitution.confirm(observations: [11: Fixture.outside]).isEmpty)
        #expect(restitution.confirm(observations: [11: Fixture.outside]) == [11])
        #expect(restitution.returned.contains(11))
        #expect(!restitution.outstanding.contains(11))
    }

    @Test("A window that is somewhere else is not confirmed back")
    func aWindowElsewhereIsNotConfirmed() {
        var restitution = Self.restitution()
        restitution.noteIssued(11, destination: Fixture.outside)

        #expect(restitution.confirm(observations: [11: Fixture.contained]).isEmpty)
        #expect(restitution.confirm(observations: [11: Fixture.contained]).isEmpty)
        #expect(restitution.outstanding.contains(11))
    }

    @Test("A window no request was issued for is never confirmed by standing still")
    func aWindowWithNoRequestIsNotConfirmed() {
        var restitution = Self.restitution()

        #expect(restitution.confirm(observations: [11: Fixture.outside]).isEmpty)
        #expect(restitution.confirm(observations: [11: Fixture.outside]).isEmpty)
        #expect(restitution.outstanding == [11, 12])
    }
}

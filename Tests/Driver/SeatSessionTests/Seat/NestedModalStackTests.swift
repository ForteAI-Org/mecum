//
//  NestedModalStackTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// Host, sheet and the dialog the sheet opens, driven through the fakes: what
/// the seat keeps while the top accessibility level shows only the innermost
/// surface, what it lets go of when a window really ends, and what it still
/// reconciles while its input is suspended for the person's focus.
///
/// The Window IDs here are the fakes' own. The live campaign's numbers are
/// evidence of what happened on one machine and are never written into a test.
@MainActor
@Suite("The nested modal stack")
struct NestedModalStackTests {

    static let sheetWindowNumber  = 778
    static let dialogWindowNumber = 779

    /// A seat holding the host window, the sheet drawn inside it, and the
    /// dialog the sheet opened, with the modal chain attested end to end.
    ///
    /// The chain is what the application says about itself: the sheet blocks
    /// the host, the dialog blocks the sheet. Nothing here says anything about
    /// which of them is readable, which is the fact each test then changes.
    static func stack() async throws -> (
        seat  : AgentSeat,
        reader: ControlledSurfaceReader,
        host  : AdoptedWindow,
        sheet : AdoptedWindow,
        dialog: AdoptedWindow
    ) {
        let sensing = FakeSensing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let seat    = makeSeat(sensing: sensing, marker: 1_881, reader: reader)

        let host = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let sheet  = try await adopt(Self.sheetWindowNumber, into: seat, sensing: sensing)
        let dialog = try await adopt(Self.dialogWindowNumber, into: seat, sensing: sensing)

        reader.roles[sheet.id]  = .dialog
        reader.roles[dialog.id] = .dialog
        reader.modals[sheet.id]  = .window(try #require(host.reference.identity))
        reader.modals[dialog.id] = .window(try #require(sheet.reference.identity))
        seat.refreshTargetReadings()
        seat.refreshTargetReadings()

        return (seat, reader, host, sheet, dialog)
    }

    private static func adopt(
        _ windowNumber: Int,
        into seat     : AgentSeat,
        sensing       : FakeSensing
    ) async throws -> AdoptedWindow {

        let offset    = CGFloat(windowNumber - FakeGeometry.windowNumber) * 60
        let reference = FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: offset, dy: offset),
            windowNumber: windowNumber
        )
        sensing.additionalWindows[windowNumber] = reference
        return try await seat.adopt(reference, platform: AppKitPlatform())
    }

    /// Every Window ID the seat still holds a record for.
    private static func held(_ seat: AgentSeat) -> [Int] {
        seat.adoptedWindows.map(\.id).sorted()
    }

    // MARK: The stack itself

    @Test("the innermost dialog is the one selectable surface and the host is only blocked")
    func theTopOfTheStackTakesTheSelection() async throws {
        let (seat, _, host, sheet, dialog) = try await Self.stack()

        let selected = try #require(seat.selectionKit.selected?.surface)
        #expect(selected.windowNumber == dialog.id)
        #expect(seat.selectionKit.isModallyBlocked(try #require(host.reference.identity)))
        #expect(seat.selectionKit.isModallyBlocked(try #require(sheet.reference.identity)))
        #expect(Self.held(seat).contains(host.id), "a blocked window is not an unassigned one")

        // The picture is the outermost window of the stack and not the sheet in
        // between, which has no surface of its own to capture either.
        let picture = seat.observationPicture(for: selected)
        #expect(picture.surface == host.reference.identity)
        #expect(picture.role == .hostedSheet(sheet: selected))
    }

    @Test("an old Window ID still on screen is never declared destroyed")
    func aLiveAncestorIsNeverDeclaredGone() async throws {
        let (seat, reader, host, sheet, dialog) = try await Self.stack()

        // What the nested dialog does to the reading: the sheet leaves the
        // application's own window scope while the window server still attests
        // it, and the pass keeps it under the child that names it.
        reader.obscured = [
            try #require(sheet.reference.identity): try #require(dialog.reference.identity),
        ]
        for _ in 0..<4 { seat.refreshTargetReadings() }

        #expect(seat.assignmentKit.inventory.surfaces[sheet.id] != nil,
                "the surface the window server still shows is still a member")
        #expect(seat.assignmentKit.inventory.surfaces[sheet.id]?.presence != .absentUncertain)
        #expect(Self.held(seat) == [host.id, sheet.id, dialog.id].sorted())
        #expect(seat.selectionKit.selected?.surface.windowNumber == dialog.id)
        #expect(seat.selectionKit.isModallyBlocked(try #require(host.reference.identity)),
                "the host stays blocked by a sheet nobody closed")
    }

    @Test("closing the child restores the parent's context under a new generation")
    func closingTheChildGivesTheParentBack() async throws {
        let (seat, reader, host, sheet, dialog) = try await Self.stack()
        let sheetIdentity  = try #require(sheet.reference.identity)
        let dialogIdentity = try #require(dialog.reference.identity)

        reader.obscured = [sheetIdentity: dialogIdentity]
        seat.refreshTargetReadings()
        let observation = try await observedReference(seat)
        #expect(observation.role.attachedSheet == dialogIdentity)
        #expect(observation.recipient == host.reference.identity,
                "the pixels are the outermost window's, the surface operated is the dialog's")
        let generationUnderTheChild = try #require(seat.selectionKit.selected?.generation)

        // Escape closes the dialog alone. The window server answers no row for
        // it, which is the one absence that proves a window ended.
        reader.obscured = [:]
        reader.destroyed = [dialogIdentity]
        reader.windowNumbers = [host.id, sheet.id]
        seat.refreshTargetReadings()

        #expect(seat.selectionKit.selected?.surface == sheetIdentity,
                "the selection goes back to the surface the dialog was opened from")
        #expect(seat.selectionKit.selected?.generation != generationUnderTheChild,
                "the parent's context is a new generation and not the child's last one")
        #expect(!seat.coherentState.hasCurrentObservation,
                "an observation of the closed dialog cannot stay current over the host's picture")
        #expect(Self.held(seat).contains(host.id), "the host is never lost")
        #expect(Self.held(seat).contains(sheet.id), "and neither is the panel the dialog was in")

        // And Escape again closes the panel, which hands the host back the
        // selection with nothing left blocking it.
        reader.destroyed = [sheetIdentity]
        reader.windowNumbers = [host.id]
        seat.refreshTargetReadings()

        #expect(seat.selectionKit.selected?.surface == host.reference.identity)
        #expect(!seat.selectionKit.isModallyBlocked(try #require(host.reference.identity)))
        #expect(Self.held(seat).contains(host.id))
    }

    // MARK: What a window that really ended leaves behind

    /// A seat holding the target and one auxiliary window of the same
    /// application, with the target operated and the auxiliary merely held.
    ///
    /// The auxiliary is what the driven applications publish beside their own
    /// windows and destroy again without telling anybody. It is deliberately
    /// not the operating target: that one has a second proof of its own, the
    /// recovery episode, and this is about every other record.
    static func auxiliary() async throws -> (
        seat     : AgentSeat,
        reader   : ControlledSurfaceReader,
        target   : AdoptedWindow,
        auxiliary: AdoptedWindow
    ) {
        let sensing = FakeSensing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let seat    = makeSeat(sensing: sensing, marker: 1_882, reader: reader)

        let target = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let auxiliary = try await adopt(Self.sheetWindowNumber, into: seat, sensing: sensing)
        _ = try await seat.switchTarget(to: target)
        seat.refreshTargetReadings()

        sensing.surfaces = [
            WindowSurface(reference: target.reference, level: 0, isVisible: true),
            WindowSurface(reference: auxiliary.reference, level: 0, isVisible: true),
        ]
        seat.enableWindowFollowing()
        return (seat, reader, target, auxiliary)
    }

    @Test("a window that really vanished leaves every register and stops blocking the handback")
    func aVanishedWindowLeavesEveryRegister() async throws {
        let (seat, reader, target, gone) = try await Self.auxiliary()
        #expect(Self.held(seat) == [target.id, gone.id].sorted())

        reader.destroyed = [try #require(gone.reference.identity)]
        reader.windowNumbers = [target.id]
        seat.refreshTargetReadings()

        #expect(Self.held(seat) == [target.id], "the record goes with the window")
        #expect(seat.assignmentKit.inventory.surfaces[gone.id] == nil, "and so does the membership")
        #expect(seat.currentTarget?.id == target.id)

        // What is left is the one real obligation. A dead window left among the
        // records refuses the handback of the whole assignment instead, and no
        // consumer can do anything about a window that is not there.
        #expect(throws: SessionFailure.assignedWindowsStillHeld(windowNumbers: [target.id])) {
            try seat.releaseAssignedApplication()
        }
    }

    // MARK: The focus suspension

    @Test("reconciliation keeps running while the input is suspended for the person's focus")
    func reconciliationSurvivesAFocusSuspension() async throws {
        let (seat, reader, target, gone) = try await Self.auxiliary()

        // The person is in the driven application, so the seat suspends. It
        // stays suspended for as long as they are there, with no deadline, and
        // the follow pass used to stand down for exactly as long.
        seat.report([.targetActivated])
        #expect(seat.state == .waiting)

        reader.destroyed = [try #require(gone.reference.identity)]
        reader.windowNumbers = [target.id]
        await seat.runWindowFollowPass()

        #expect(seat.state == .waiting, "reading the world does not end the person's turn")
        #expect(Self.held(seat) == [target.id],
                "a window that ended leaves the registers the recovery is waiting on")
        #expect(seat.assignmentKit.inventory.surfaces[gone.id] == nil)
    }

    @Test("a pass suspended for focus moves nothing")
    func aSuspendedPassMovesNothing() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let seat    = makeSeat(sensing: sensing, placing: placing, marker: 1_883, reader: reader)
        _ = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        sensing.surfaces = [WindowSurface(
            reference: FakeGeometry.adoptedWindow,
            level    : 0,
            isVisible: true
        )]
        seat.enableWindowFollowing()
        seat.report([.targetActivated])
        #expect(seat.state == .waiting)

        // A window of the driven application appears outside the seat while the
        // person holds the focus. Reconciliation reads it; nothing brings it in
        // until they give the seat back.
        let stray = Self.reference(Self.dialogWindowNumber)
        sensing.additionalWindows[stray.windowNumber] = stray
        sensing.surfaces?.append(
            WindowSurface(reference: stray, level: 0, isVisible: true)
        )
        let movesBefore = placing.moves.count
        await seat.runWindowFollowPass()

        #expect(placing.moves.count == movesBefore, "a suspended pass reads and does not move")
        #expect(!Self.held(seat).contains(stray.windowNumber))
    }

    /// One window of the driven application at an origin of its own, outside
    /// the records: what the follow pass would bring in if it were running.
    private static func reference(_ windowNumber: Int) -> WindowReference {
        let offset = CGFloat(windowNumber - FakeGeometry.windowNumber) * 60
        return FakeGeometry.reference(
            frame       : FakeGeometry.userSeatWindow.frame.offsetBy(dx: offset, dy: offset),
            windowNumber: windowNumber
        )
    }
}

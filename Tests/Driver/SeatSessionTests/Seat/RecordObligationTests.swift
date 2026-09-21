//
//  RecordObligationTests.swift
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

/// What a held record still says about itself after the seat has read the
/// window again: the obligation the adoption's evidence decided, carried
/// through a stage and a target switch to the release that asks for it.
///
/// The oracle for "nothing was repositioned" is the placing fake's own write
/// log and not the flag under test: a surface owed nothing back is proved
/// undisturbed by the absence of a write, which is the same fact the person
/// would see on screen.
///
/// The Window IDs here are the fakes' own. The live campaign's numbers are
/// evidence of what happened on one machine and are never written into a test.
@MainActor
@Suite("Obligations of a held record")
struct RecordObligationTests {

    static let sheetWindowNumber = 878

    struct Panel {
        let seat   : AgentSeat
        let sensing: FakeSensing
        let placing: FakePlacing
        let host   : AdoptedWindow
        let sheet  : AdoptedWindow
    }

    /// A seat holding an ordinary window and a sheet drawn inside it.
    ///
    /// The modal block is attested **before** the sheet is taken in, because
    /// that is when the obligation is decided: a relation attested afterwards
    /// would leave the record saying the sheet owes a return, which is the
    /// state this suite must be able to tell apart from the defect.
    static func panel() async throws -> Panel {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let seat    = makeSeat(
            sensing: sensing,
            placing: placing,
            marker : 1_907,
            reader : reader
        )

        let host = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )

        let inbound = FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: 60, dy: 60),
            windowNumber: Self.sheetWindowNumber
        )
        sensing.additionalWindows[Self.sheetWindowNumber] = inbound
        reader.roles[Self.sheetWindowNumber]  = .dialog
        reader.modals[Self.sheetWindowNumber] = .window(try #require(host.reference.identity))
        seat.refreshTargetReadings()
        seat.refreshTargetReadings()

        let sheet = try await seat.adopt(inbound, platform: AppKitPlatform())
        sensing.additionalWindows[Self.sheetWindowNumber] = sheet.reference

        return Panel(seat: seat, sensing: sensing, placing: placing, host: host, sheet: sheet)
    }

    /// The record the seat holds right now, which is the one a release reads.
    static func held(_ panel: Panel, _ windowNumber: Int) throws -> AdoptedWindow {
        try #require(panel.seat.adoptedWindows.first { $0.id == windowNumber })
    }

    @Test("a sheet keeps its exemption through staging, a target switch and its release")
    func theSheetOwesNothingAllTheWayThrough() async throws {

        let panel = try await Self.panel()
        #expect(panel.sheet.owesNoReturn,
                "the modal block was the evidence the adoption had")

        let staged = try await panel.seat.stage(panel.sheet)
        #expect(staged.owesNoReturn, "staging reads geometry, not obligations")
        #expect(try Self.held(panel, panel.sheet.id).owesNoReturn)

        let switched = try await panel.seat.switchTarget(to: staged)
        #expect(switched.owesNoReturn, "a target switch reads geometry, not obligations")
        #expect(try Self.held(panel, panel.sheet.id).owesNoReturn)

        // Identity and provenance came through the same two rebuilds.
        let current = try Self.held(panel, panel.sheet.id)
        #expect(current.reference.hasSameIdentity(as: panel.sheet.reference))
        #expect(current.originalFrame == panel.sheet.originalFrame)
        #expect(current.originalServerFrame == panel.sheet.originalServerFrame)

        let writesBefore = panel.placing.moves.count
        let outcome      = await panel.seat.release(current)

        #expect(outcome == .returned)
        #expect(panel.placing.moves.count == writesBefore,
                "a surface with no place of its own is never moved on its own")
        #expect(panel.seat.adoptedWindows.map(\.id) == [panel.host.id])
    }

    @Test("an ordinary window keeps its real return through the same path")
    func theOrdinaryWindowIsStillOwedItsFrame() async throws {

        let panel = try await Self.panel()
        panel.placing.onMove = { origin in
            panel.sensing.geometry = FakeGeometry.userSeatWindow.replacingFrame(
                CGRect(origin: origin, size: FakeGeometry.windowSize)
            )
        }
        #expect(!panel.host.owesNoReturn)

        let staged = try await panel.seat.stage(panel.host)
        #expect(!staged.owesNoReturn)

        let switched = try await panel.seat.switchTarget(to: staged)
        #expect(!switched.owesNoReturn)
        #expect(try Self.held(panel, panel.host.id).originalFrame
                == FakeGeometry.userSeatWindow.frame)

        let outcome = await panel.seat.release(try Self.held(panel, panel.host.id))

        #expect(outcome == .returned)
        #expect(panel.placing.moves.last == FakeGeometry.userSeatWindow.frame.origin,
                "the window the seat borrowed is written back where it was found")
    }
}

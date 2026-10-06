//
//  WindowsElsewhereTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatDriving
import SeatInput
@testable import SeatSession
import Testing

/// Another window of the driven application that the seat cannot take in, and
/// the target it does hold.
///
/// A window left on the person's screen with no qualified way to move it, a
/// window whose visibility no reading decides, and the target its application
/// stopped listing for a moment each used to stop the seat: the first two
/// suspended every observation, the third dropped the target and every
/// observation refused as `notAdopted` until the session was closed and opened
/// again. The rows reproduce each one on the controlled seat, and keep a modal
/// that blocks the target refusing as before.
@MainActor
@Suite("Windows of the application outside the observation")
struct WindowsElsewhereTests {

    static let otherWindowNumber = 781

    /// Where the person's own display keeps a window the seat never moved.
    static let personsScreen = CGRect(x: 900, y: 300, width: 400, height: 300)

    static func seat(
        marker : Int64,
        sensing: FakeSensing = FakeSensing(),
        placing: FakePlacing = FakePlacing(),
        sender : FakeSender  = FakeSender()
    ) async throws -> (seat: AgentSeat, window: AdoptedWindow, reader: ControlledSurfaceReader) {

        let reader = ControlledSurfaceReader(sensing: sensing)
        let seat   = makeSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : marker,
            reader : reader,
            source : ControlledObservationSource(sensing: sensing),
            clock  : ControlledContentClock()
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        _ = try await observe(seat)
        return (seat, window, reader)
    }

    static func click(on window: AdoptedWindow) -> InputCommand {
        let frame = window.reference.frame
        return .click(InputLocation(
            screenPoint       : CGPoint(x: frame.midX, y: frame.midY),
            windowPointFromTop: CGPoint(x: frame.width / 2, y: frame.height / 2)
        ))
    }

    static func names(_ causes: [SelectionSuspension], _ windowNumber: Int) -> Bool {
        causes.contains { cause in
            switch cause {
                case .visibilityUncertain(let surface):
                    surface.windowNumber == windowNumber
                case .containmentNotVerified(let blocks):
                    blocks.contains {
                        $0 == .surfaceOutsideSeat(windowNumber: windowNumber)
                            || $0 == .surfaceAbsent(windowNumber: windowNumber)
                    }
                default:
                    false
            }
        }
    }

    @Test("a window undecided inside the seat is carried without a notice, and the target is observed and driven")
    func anUndecidedWindowIsNamed() async throws {

        let sender = FakeSender()
        let sensing = FakeSensing()
        let (seat, window, reader) = try await Self.seat(marker: 1_941, sensing: sensing, sender: sender)

        // A dialog the application made inside the seat, whose AXModal nobody can read.
        let dialog = FakeGeometry.reference(
            frame       : CGRect(x: 1600, y: 100, width: 300, height: 200),
            windowNumber: Self.otherWindowNumber
        )
        sensing.additionalWindows[Self.otherWindowNumber] = dialog
        reader.roles[Self.otherWindowNumber]        = .dialog
        reader.visibilities[Self.otherWindowNumber] = .uncertain

        let delivery = try await observe(seat)
        #expect(delivery.reference.recipient == window.reference.identity)
        #expect(delivery.causesElsewhere.contains(.visibilityUncertain(try #require(dialog.identity))))
        #expect(delivery.shownOutsideSeat.isEmpty, "nothing is on the person's screen to tell them about")

        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click(on: window), observation: delivery.reference, turn: turn)
        try seat.confirm(receipt, .observed)
        try seat.release(turn)
        #expect(sender.sent.count == 1)
    }

    @Test("a window left on the person's screen with no way to move it is named, and nothing moves")
    func aWindowOnThePersonsScreenIsNamed() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, window, reader) = try await Self.seat(
            marker : 1_942,
            sensing: sensing,
            placing: placing,
            sender : sender
        )
        let movesBefore = placing.moves.count

        let outside = FakeGeometry.reference(
            frame       : Self.personsScreen,
            windowNumber: Self.otherWindowNumber
        )
        sensing.additionalWindows[Self.otherWindowNumber] = outside

        let first = try await observe(seat)
        #expect(first.reference.recipient == window.reference.identity)
        #expect(Self.names(first.causesElsewhere, Self.otherWindowNumber))
        #expect(first.shownOutsideSeat == [try #require(outside.identity)], "the one case worth a notice")
        #expect(placing.moves.count == movesBefore, "a window nobody can move is left where it is")

        // The next observation reads it again, and it is still named.
        let second = try await observe(seat)
        #expect(Self.names(second.causesElsewhere, Self.otherWindowNumber))

        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click(on: window), observation: second.reference, turn: turn)
        try seat.confirm(receipt, .observed)
        try seat.release(turn)
        #expect(sender.sent.count == 1)

        // Closed by the person, the window server proves it gone and it is named no more.
        sensing.additionalWindows[Self.otherWindowNumber] = nil
        reader.destroyed = [try #require(outside.identity)]
        let after = try await observe(seat)
        #expect(!Self.names(after.causesElsewhere, Self.otherWindowNumber))
        #expect(after.shownOutsideSeat.isEmpty)
    }

    @Test("windows the application hid inside the seat after Create give no notice")
    func windowsHiddenByTheApplicationGiveNoNotice() async throws {

        let sensing = FakeSensing()
        let (seat, manager, reader) = try await Self.seat(marker: 1_946, sensing: sensing)

        // The Create New Project dialog, born in the seat over the Project Manager.
        let create = FakeGeometry.reference(
            frame       : CGRect(x: 2000, y: 400, width: 520, height: 200),
            windowNumber: Self.otherWindowNumber
        )
        sensing.additionalWindows[Self.otherWindowNumber] = create
        reader.roles[Self.otherWindowNumber] = .dialog
        await seat.ownWindowBornInSeat(create, level: 8)

        // Create: the project's window is born and raised, and the application hides the
        // manager and the dialog where they stand, which no reading decides yet.
        let project = FakeGeometry.reference(
            frame       : CGRect(x: 1600, y: 100, width: 1345, height: 949),
            windowNumber: Self.otherWindowNumber + 1
        )
        sensing.additionalWindows[project.windowNumber] = project
        await seat.ownWindowBornInSeat(project, level: 0)
        reader.visibilities[manager.id]             = .uncertain
        reader.visibilities[Self.otherWindowNumber] = .uncertain
        reader.recency = [RecencyClaim(
            surface              : try #require(project.identity),
            signal               : .appeared,
            provenance           : .qualifiedFrontOrderAttestation,
            origin               : .application(provenance: .qualifiedRaiseAttribution),
            observedAtNanoseconds: 100
        )]

        let delivery = try await observe(seat)
        #expect(delivery.reference.recipient == project.identity)
        #expect(Self.names(delivery.causesElsewhere, manager.id))
        #expect(Self.names(delivery.causesElsewhere, Self.otherWindowNumber))
        #expect(delivery.shownOutsideSeat.isEmpty, "a window its application hid is nobody's to close")
    }

    @Test("a modal on the person's screen that blocks the target still refuses the observation")
    func aBlockingModalElsewhereStillRefuses() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, _, reader) = try await Self.seat(marker: 1_943, sensing: sensing, sender: sender)

        sensing.additionalWindows[Self.otherWindowNumber] = FakeGeometry.reference(
            frame       : Self.personsScreen,
            windowNumber: Self.otherWindowNumber
        )
        reader.roles[Self.otherWindowNumber]  = .dialog
        reader.modals[Self.otherWindowNumber] = .application
        seat.refreshTargetReadings()

        guard case .failure(.suspended(let causes)) = await seat.observe() else {
            Issue.record("a modal that blocks the target must still refuse its observation")
            return
        }
        #expect(causes.contains { cause in
            guard case .containmentNotVerified(let blocks) = cause else { return false }
            let clause = "window \(Self.otherWindowNumber) of the application is open on the person's screen"
            return blocks.contains { $0.contains(clause) }
        }, "the refusal names the modal and where it is")
        #expect(sender.sent.isEmpty)
    }

    @Test("a target its application stops listing for a moment is kept, and a borrow observes it again")
    func aWithdrawnTargetIsKept() async throws {

        let sensing = FakeSensing()
        let (seat, window, reader) = try await Self.seat(marker: 1_944, sensing: sensing)
        let borrow   = SeatTarget(borrowing: SeatHost(), seat: seat)
        let identity = try #require(window.reference.identity)
        _ = try await borrow.observe()

        // The window server still shows it; the application lists no window.
        reader.windowNumbers = []
        reader.withdrawn     = [identity]
        seat.refreshTargetReadings()
        reader.withdrawn     = []
        #expect(seat.currentTarget?.id == window.id, "nothing held could take over")
        #expect(seat.adoptedWindows.map(\.id) == [window.id])

        // Listed again, it is observed through the borrow without closing anything.
        reader.windowNumbers = nil
        let delivery = try await borrow.observe()
        #expect(delivery.reference.recipient == identity)
        #expect(seat.currentTarget?.id == window.id)
        await borrow.stop()
    }

    @Test("a kept target is let go once another held window takes over")
    func aKeptTargetIsLetGoWhenAnotherTakesOver() async throws {

        let sensing = FakeSensing()
        let (seat, window, reader) = try await Self.seat(marker: 1_945, sensing: sensing)
        let identity = try #require(window.reference.identity)

        reader.windowNumbers = [Self.otherWindowNumber]
        reader.withdrawn     = [identity]
        seat.refreshTargetReadings()
        reader.withdrawn     = []
        #expect(seat.currentTarget?.id == window.id)

        // The application's next window is born in the seat and owned there.
        let next = FakeGeometry.reference(
            frame       : CGRect(x: 1600, y: 100, width: 600, height: 400),
            windowNumber: Self.otherWindowNumber
        )
        sensing.additionalWindows[Self.otherWindowNumber] = next
        seat.refreshTargetReadings()
        await seat.ownWindowBornInSeat(next, level: 0)
        seat.refreshTargetReadings()

        #expect(seat.currentTarget?.id == Self.otherWindowNumber)
        #expect(seat.adoptedWindows.map(\.id) == [Self.otherWindowNumber],
                "the withdrawn record is not left held behind the new target")
    }
}

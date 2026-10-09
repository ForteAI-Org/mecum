//
//  WindowSpaceReturnTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The return of a window is only `returned` when it is also back on the
/// desktop it came from, and a window the seat finds already inside the Virtual
/// Display still owes the place it had when the application was handed over
/// (ADR 0037). The desktops are the fake window server's: the seat reads them
/// and never writes one.
@MainActor
@Suite("A window returns to its own desktop")
struct WindowSpaceReturnTests {

    static let homeDesktop    = 1
    static let otherDesktop   = 2419
    static let virtualDesktop = 2488

    /// The built-in display with two desktops, the first shown. The display id
    /// is the one the seat read for the window, so the layout names it.
    static func layout(display: CGDirectDisplayID?, current: Int = homeDesktop) -> DesktopLayout {
        DesktopLayout(displays: [
            .init(displayID: display, spaces: [homeDesktop, otherDesktop], current: current),
        ])
    }

    /// The window server as it is before the seat moves anything: the window is in
    /// the User Seat, and the seat's own move is what brings it onto the Virtual
    /// Display.
    static func startPhysical(_ sensing: FakeSensing, _ placing: FakePlacing) {
        sensing.geometry = FakeGeometry.userSeatWindow
        placing.onMove = { _ in
            sensing.geometry  = FakeGeometry.adoptedWindow
            placing.bodyFrame = FakeGeometry.adoptedWindow.frame
        }
    }

    /// A seat that adopted the user's window from `homeDesktop`, with the window
    /// ready to go home: its move lands it at the original frame and leaves its
    /// desktop where `afterReturn` says.
    static func adoptedWindow(
        layoutAtReturn: ((AdoptedWindow) -> DesktopLayout?)? = nil
    ) async throws -> (seat: AgentSeat, sensing: FakeSensing, placing: FakePlacing, window: AdoptedWindow) {

        let sensing  = FakeSensing()
        let placing  = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        sensing.desktops = layout(display: nil)
        sensing.windowDesktops[original.windowNumber] = [homeDesktop]
        Self.startPhysical(sensing, placing)
        let seat   = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(original)
        placing.onMove = { _ in
            sensing.geometry  = original
            placing.bodyFrame = original.frame
        }
        return (seat, sensing, placing, window)
    }

    @Test("the desktop the window is on is recorded before the seat moves it")
    func adoptionRecordsTheDesktop() async throws {
        let (_, _, _, window) = try await Self.adoptedWindow()
        #expect(window.originalSpaceID == Self.homeDesktop)
    }

    @Test("a window back on its desktop is returned")
    func sameDesktopIsReturned() async throws {
        let (seat, _, _, window) = try await Self.adoptedWindow()
        #expect(await seat.release(window) == .returned)
    }

    @Test("a window back at its frame on another desktop is not returned")
    func otherDesktopIsNamed() async throws {
        let (seat, sensing, _, window) = try await Self.adoptedWindow()
        sensing.windowDesktops[window.id] = [Self.otherDesktop]
        let outcome = await seat.release(window)
        #expect(outcome == .returnedToOtherSpace)
        // The seat has nothing more to give back: no pending restoration, no
        // obligation, and the ledger says what happened.
        #expect(!seat.hasPendingWindowRestorations)
        #expect(!seat.hasOutstandingWindowReturns)
        #expect(seat.releaseLedger[window.id] == .returnedToOtherSpace)
    }

    @Test("a desktop that follows the frame a moment later is still returned")
    func lateDesktopIsReturned() async throws {
        let (seat, sensing, _, window) = try await Self.adoptedWindow()
        var reads = 0
        sensing.windowDesktopReader = { _ in
            reads += 1
            return [reads <= 5 ? Self.virtualDesktop : Self.homeDesktop]
        }
        #expect(await seat.release(window) == .returned)
        #expect(reads > 5)
    }

    @Test("a window left on the virtual display's desktop is not returned either")
    func virtualDesktopIsAnotherDesktop() async throws {
        let (seat, sensing, _, window) = try await Self.adoptedWindow()
        sensing.windowDesktops[window.id] = [Self.virtualDesktop]
        #expect(await seat.release(window) == .returnedToOtherSpace)
    }

    @Test("a desktop that is gone is replaced by the one its display shows now")
    func closedDesktopFallsBackToTheCurrentOne() async throws {
        let (seat, sensing, _, window) = try await Self.adoptedWindow()
        // The window was adopted at the desktop with id 1, which the person has
        // since closed: the display shows desktop 3 now.
        sensing.desktops = DesktopLayout(displays: [
            .init(displayID: window.originalDisplayID, spaces: [3, 4], current: 3),
        ])
        sensing.windowDesktops[window.id] = [3]
        try #require(window.originalDisplayID != nil)
        #expect(await seat.release(window) == .returned)

        let (again, againSensing, _, secondWindow) = try await Self.adoptedWindow()
        againSensing.desktops = DesktopLayout(displays: [
            .init(displayID: secondWindow.originalDisplayID, spaces: [3, 4], current: 3),
        ])
        againSensing.windowDesktops[secondWindow.id] = [4]
        #expect(await again.release(secondWindow) == .returnedToOtherSpace)
    }

    @Test("a desktop that cannot be read leaves the return as the frames proved it")
    func unreadableDesktopClaimsNothing() async throws {
        let (seat, sensing, _, window) = try await Self.adoptedWindow()
        sensing.desktops = nil
        #expect(await seat.release(window) == .returned)

        let (again, againSensing, _, secondWindow) = try await Self.adoptedWindow()
        againSensing.windowDesktops[secondWindow.id] = nil
        #expect(await again.release(secondWindow) == .returned)
    }

    @Test("a window whose desktop was never read is returned on the frames alone")
    func neverReadDesktopClaimsNothing() async throws {
        let sensing  = FakeSensing()
        let placing  = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        sensing.desktops = Self.layout(display: nil)
        Self.startPhysical(sensing, placing)
        let seat   = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(original)
        #expect(window.originalSpaceID == nil)
        placing.onMove = { _ in
            sensing.geometry  = original
            placing.bodyFrame = original.frame
        }
        sensing.windowDesktops[window.id] = [Self.otherDesktop]
        #expect(await seat.release(window) == .returned)
    }

    // MARK: A window found inside the Virtual Display

    /// A seat holding the target, with a second window of the same application
    /// that stood in the User Seat when the first was moved and is inside the
    /// Virtual Display when the seat first owns it.
    static func seatWithAWindowTakenInPlace(
        recordsOrigins: Bool
    ) async throws -> (seat: AgentSeat, sensing: FakeSensing, placing: FakePlacing,
                       taken: AdoptedWindow, physical: WindowReference, body: CGRect) {

        let second   = MultiWindowTests.secondWindowNumber
        let physical = FakeGeometry.reference(
            frame       : CGRect(x: 700, y: 300, width: 600, height: 400),
            windowNumber: second
        )
        // The application's own body differs from the server's rectangle by a few
        // points, as MarkEdit's does, so the two sources are not interchangeable.
        let body = CGRect(x: 700, y: 300, width: 597, height: 400)

        let sensing = FakeSensing()
        let placing = FakePlacing()
        sensing.desktops = layout(display: nil)
        sensing.windowDesktops[FakeGeometry.windowNumber] = [homeDesktop]
        sensing.windowDesktops[second] = [otherDesktop]
        if recordsOrigins {
            sensing.surfaces = [
                WindowSurface(reference: FakeGeometry.userSeatWindow, level: 0, isVisible: true),
                WindowSurface(reference: physical, level: 0, isVisible: true),
            ]
        }
        placing.bodyFrames[second] = body

        Self.startPhysical(sensing, placing)
        let seat = makeSeat(sensing: sensing, placing: placing)
        _ = try await seat.adopt(FakeGeometry.userSeatWindow)
        sensing.surfaces = []

        // Moved into the Virtual Display by the time the seat owns it.
        let inside = MultiWindowTests.reference(second)
        sensing.additionalWindows[second] = inside
        placing.bodyFrames[second] = inside.frame
        let taken = try await seat.integrateDetectedWindow(
            inside,
            platform    : AppKitPlatform(),
            takenInPlace: true
        )
        return (seat, sensing, placing, taken, physical, body)
    }

    @Test("a window taken in place owes the place it had before the first move")
    func takenInPlaceKeepsItsOrigin() async throws {
        let (_, _, _, taken, physical, body) = try await Self.seatWithAWindowTakenInPlace(recordsOrigins: true)
        #expect(taken.originalFrame == body)
        #expect(taken.originalServerFrame == physical.frame)
        #expect(taken.originalSpaceID == Self.otherDesktop)
    }

    @Test("and goes back to it, on its own desktop")
    func takenInPlaceGoesHome() async throws {
        let (seat, sensing, placing, taken, physical, body) =
            try await Self.seatWithAWindowTakenInPlace(recordsOrigins: true)
        let number = taken.id
        placing.onMove = { origin in
            sensing.additionalWindows[number] = physical.replacingFrame(
                CGRect(origin: origin, size: physical.frame.size)
            )
            placing.bodyFrames[number] = CGRect(origin: origin, size: body.size)
        }
        sensing.windowDesktops[number] = [Self.otherDesktop]
        #expect(await seat.release(taken) == .returned)
        #expect(placing.moves.last == body.origin)

        // The same return that lands on another desktop is named, not hidden.
        let (second, secondSensing, secondPlacing, secondTaken, secondPhysical, secondBody) =
            try await Self.seatWithAWindowTakenInPlace(recordsOrigins: true)
        secondPlacing.onMove = { origin in
            secondSensing.additionalWindows[secondTaken.id] = secondPhysical.replacingFrame(
                CGRect(origin: origin, size: secondPhysical.frame.size)
            )
            secondPlacing.bodyFrames[secondTaken.id] = CGRect(origin: origin, size: secondBody.size)
        }
        secondSensing.windowDesktops[secondTaken.id] = [Self.homeDesktop]
        #expect(await second.release(secondTaken) == .returnedToOtherSpace)
    }

    @Test("windows that stay on another desktop share one wait, not one each")
    func stuckWindowsShareTheWait() async throws {
        let (seat, sensing, placing, taken, physical, body) =
            try await Self.seatWithAWindowTakenInPlace(recordsOrigins: true)
        let number = taken.id
        placing.onMove = { origin in
            if sensing.geometry?.windowNumber == FakeGeometry.windowNumber {
                sensing.geometry = FakeGeometry.userSeatWindow
                placing.bodyFrame = FakeGeometry.userSeatWindow.frame
            }
            sensing.additionalWindows[number] = physical.replacingFrame(
                CGRect(origin: origin, size: physical.frame.size)
            )
            placing.bodyFrames[number] = CGRect(origin: origin, size: body.size)
        }
        sensing.windowDesktops[FakeGeometry.windowNumber] = [Self.otherDesktop]
        sensing.windowDesktops[number] = [Self.virtualDesktop]

        let started  = ContinuousClock.now
        let outcomes = await seat.releaseAllWindows(.returnToUserSeat)
        let elapsed  = ContinuousClock.now - started

        #expect(outcomes[FakeGeometry.windowNumber] == .returnedToOtherSpace)
        #expect(outcomes[number] == .returnedToOtherSpace)
        // One budget of one second for both, where one each would take two.
        #expect(elapsed < .seconds(1.9))
    }

    @Test("without the handover reading a window taken in place owes what it is found at")
    func takenInPlaceWithoutAnOriginIsAsBefore() async throws {
        let (_, _, _, taken, _, _) = try await Self.seatWithAWindowTakenInPlace(recordsOrigins: false)
        let inside = MultiWindowTests.reference(MultiWindowTests.secondWindowNumber)
        #expect(taken.originalFrame == inside.frame)
        #expect(taken.originalSpaceID == nil)
    }
}

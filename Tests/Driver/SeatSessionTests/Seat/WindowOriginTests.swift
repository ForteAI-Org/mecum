//
//  WindowOriginTests.swift
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

/// Where a window stood before the display moved it, and what the return does
/// with that (ADR 0037). The display's creation can pull every window of the
/// application into the Virtual Display before the seat makes its first move,
/// the target included, so the place has to be read before that and carried in.
@MainActor
@Suite("A window's own place is read before the display moves it")
struct WindowOriginTests {

    static let builtIn: CGDirectDisplayID = 1
    static let external: CGDirectDisplayID = 3

    static let builtInHome   = 1
    static let externalHome  = 2079
    static let virtualSpace  = 2488

    /// The built-in display with two desktops, the first shown, and an external
    /// display with two, its first shown: the reference machine's layout.
    static var twoDisplays: DesktopLayout {
        DesktopLayout(displays: [
            .init(displayID: builtIn,  spaces: [2419, builtInHome], current: builtInHome),
            .init(displayID: external, spaces: [externalHome, 2313], current: externalHome),
        ])
    }

    // MARK: The reading

    @Test("every ordinary window outside the Virtual Display keeps its own display and desktop")
    func readKeepsEachWindowsPlace() {
        let target   = FakeGeometry.userSeatWindow
        let beside   = FakeGeometry.reference(
            frame: CGRect(x: -400, y: -1200, width: 600, height: 400), windowNumber: 778)
        let inside   = FakeGeometry.reference(
            frame: FakeGeometry.virtual.insetBy(dx: 100, dy: 100), windowNumber: 779)
        let helper   = FakeGeometry.reference(
            frame: CGRect(x: 10, y: 10, width: 60, height: 20), windowNumber: 780)
        let unseen   = FakeGeometry.reference(
            frame: CGRect(x: 20, y: 20, width: 300, height: 200), windowNumber: 781)
        let stranger = FakeGeometry.reference(
            frame: CGRect(x: 30, y: 30, width: 300, height: 200), processID: 9_001, windowNumber: 782)

        let origins = WindowOrigin.read(
            surfaces: [
                WindowSurface(reference: target,   level: 0,  isVisible: true),
                WindowSurface(reference: beside,   level: 0,  isVisible: true),
                WindowSurface(reference: inside,   level: 0,  isVisible: true),
                WindowSurface(reference: helper,   level: 25, isVisible: true),
                WindowSurface(reference: unseen,   level: 0,  isVisible: false),
                WindowSurface(reference: stranger, level: 0,  isVisible: true),
            ],
            of       : target.identity!.process,
            excluding: FakeGeometry.virtual,
            body     : { $0.frame.insetBy(dx: 1, dy: 0) },
            display  : { $0.midY < 0 ? Self.external : Self.builtIn },
            spaces   : { $0 == 778 ? [Self.externalHome] : [Self.builtInHome] }
        )

        #expect(Set(origins.keys.map(\.windowNumber)) == [FakeGeometry.windowNumber, 778])
        let one = origins[target.identity!]
        #expect(one?.displayID == Self.builtIn)
        #expect(one?.spaceID == Self.builtInHome)
        #expect(one?.body == target.frame.insetBy(dx: 1, dy: 0))
        #expect(one?.serverFrame == target.frame)
        let two = origins[beside.identity!]
        #expect(two?.displayID == Self.external)
        #expect(two?.spaceID == Self.externalHome)
    }

    @Test("a window on several desktops, or a server rectangle that is not the body, claims no desktop or oracle")
    func readClaimsOnlyWhatItCanProve() {
        let target = FakeGeometry.userSeatWindow
        let origins = WindowOrigin.read(
            surfaces: [WindowSurface(reference: target, level: 0, isVisible: true)],
            of       : target.identity!.process,
            excluding: nil,
            body     : { _ in CGRect(x: 0, y: 0, width: 20, height: 20) },
            display  : { _ in Self.builtIn },
            spaces   : { _ in [1, 2419] }
        )
        let one = origins[target.identity!]
        #expect(one?.spaceID == nil)
        #expect(one?.serverFrame == nil)
        #expect(one?.body == CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    // MARK: A window the application moved before the seat did

    @Test("a window already on the Virtual Display claims no desktop it cannot prove")
    func targetMovedBeforeTheFirstMoveClaimsNoDesktop() async throws {
        // The seat is handed the rectangle read before the display existed, and
        // the window server already shows the window inside the Virtual Display,
        // on that display's desktop. Nothing says which desktop was its own.
        let sensing  = FakeSensing()
        let placing  = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        sensing.desktops = DesktopLayout(displays: [
            .init(displayID: nil, spaces: [WindowSpaceReturnTests.homeDesktop, 2419], current: 1),
            .init(displayID: 7, spaces: [Self.virtualSpace], current: Self.virtualSpace),
        ])
        sensing.windowDesktops[original.windowNumber] = [Self.virtualSpace]
        let seat   = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(original)
        #expect(window.originalSpaceID == nil)

        placing.onMove = { _ in
            sensing.geometry  = original
            placing.bodyFrame = original.frame
            sensing.windowDesktops[original.windowNumber] = [WindowSpaceReturnTests.homeDesktop]
        }
        #expect(await seat.release(window) == .returned)
        #expect(!seat.hasOutstandingWindowReturns)
    }

    // MARK: The windows come back to the display and desktop they had

    /// One window as the display's creation left it: inside the Virtual Display,
    /// with the place it had before.
    struct Pulled {
        let number: Int
        let origin: WindowOrigin
        let space : Int
    }

    @Test("windows pulled in before the first move go back to their display and desktop, and only the stuck one is named")
    func pulledWindowsGoHome() async throws {
        let targetFrame = FakeGeometry.userSeatWindow.frame
        let pulled = [
            Pulled(number: FakeGeometry.windowNumber,
                   origin: WindowOrigin(body: targetFrame, serverFrame: targetFrame,
                                        displayID: Self.builtIn, spaceID: Self.builtInHome),
                   space : Self.builtInHome),
            Pulled(number: MultiWindowTests.secondWindowNumber,
                   origin: WindowOrigin(body: CGRect(x: -400, y: -1200, width: 597, height: 400),
                                        serverFrame: CGRect(x: -400, y: -1200, width: 600, height: 400),
                                        displayID: Self.external, spaceID: Self.externalHome),
                   space : Self.externalHome),
            Pulled(number: MultiWindowTests.thirdWindowNumber,
                   origin: WindowOrigin(body: CGRect(x: -300, y: -1100, width: 597, height: 400),
                                        serverFrame: CGRect(x: -300, y: -1100, width: 600, height: 400),
                                        displayID: Self.external, spaceID: Self.externalHome),
                   space : Self.externalHome),
        ]

        let sensing = FakeSensing()
        let placing = FakePlacing()
        sensing.desktops = Self.twoDisplays
        // Everything is inside the Virtual Display already, on its desktop.
        for window in pulled { sensing.windowDesktops[window.number] = [Self.virtualSpace] }
        let seat = makeSeat(sensing: sensing, placing: placing)
        seat.noteOrigins(Dictionary(uniqueKeysWithValues: pulled.map {
            (FakeGeometry.identity(windowNumber: $0.number), $0.origin)
        }))

        // The first window arrives with the rectangle read before the display
        // existed, as the broker hands it; the others are found in place.
        let target = try await seat.adopt(FakeGeometry.userSeatWindow)
        var taken: [AdoptedWindow] = []
        for number in [MultiWindowTests.secondWindowNumber, MultiWindowTests.thirdWindowNumber] {
            let inside = MultiWindowTests.reference(number)
            sensing.additionalWindows[number] = inside
            placing.bodyFrames[number] = inside.frame
            taken.append(try await seat.integrateDetectedWindow(
                inside, platform: AppKitPlatform(), takenInPlace: true))
        }

        #expect(target.originalDisplayID == Self.builtIn)
        #expect(target.originalSpaceID == Self.builtInHome)
        for window in taken {
            #expect(window.originalDisplayID == Self.external)
            #expect(window.originalSpaceID == Self.externalHome)
            #expect(window.originalFrame.origin.y < 0, "owes the external display, not the Virtual Display")
        }

        // A move lands the window at its origin, and its desktop follows the
        // display it lands on, except for the third window, which stays behind.
        placing.onMove = { origin in
            guard let window = pulled.first(where: { $0.origin.body.origin == origin }) else { return }
            let frame = window.origin.serverFrame ?? window.origin.body
            if window.number == FakeGeometry.windowNumber { sensing.geometry = FakeGeometry.userSeatWindow }
            else { sensing.additionalWindows[window.number] = FakeGeometry.reference(
                frame: frame, windowNumber: window.number) }
            placing.bodyFrames[window.number] = window.origin.body
            sensing.windowDesktops[window.number] =
                [window.number == MultiWindowTests.thirdWindowNumber ? Self.virtualSpace : window.space]
        }

        let outcomes = await seat.releaseAllWindows(.returnToUserSeat)

        #expect(outcomes[FakeGeometry.windowNumber] == .returned)
        #expect(outcomes[MultiWindowTests.secondWindowNumber] == .returned)
        #expect(outcomes[MultiWindowTests.thirdWindowNumber] == .returnedToOtherSpace)
        #expect(placing.moves.contains(pulled[1].origin.body.origin))
        #expect(placing.moves.contains(pulled[2].origin.body.origin))
    }

    @Test("a window the person moved after it was read owes where it is, not where it was")
    func aMovedWindowOwesItsCurrentPlace() async throws {
        let moved = FakeGeometry.reference(frame: CGRect(x: 400, y: 300, width: 800, height: 600))
        let stale = WindowOrigin(
            body: FakeGeometry.userSeatWindow.frame, serverFrame: FakeGeometry.userSeatWindow.frame,
            displayID: Self.builtIn, spaceID: Self.builtInHome)

        let sensing = FakeSensing()
        let placing = FakePlacing()
        sensing.geometry = moved
        sensing.desktops = Self.twoDisplays
        sensing.windowDesktops[moved.windowNumber] = [2419]
        placing.onMove = { _ in
            sensing.geometry  = FakeGeometry.adoptedWindow
            placing.bodyFrame = FakeGeometry.adoptedWindow.frame
        }
        let seat = makeSeat(sensing: sensing, placing: placing)
        seat.noteOrigins([moved.identity!: stale])

        let window = try await seat.adopt(moved)
        #expect(window.originalFrame == moved.frame)
        #expect(window.originalSpaceID == 2419)
    }

    @Test("a place read before the display is not replaced by a later reading of the same window")
    func theEarlierReadingWins() async throws {
        let first = WindowOrigin(
            body: FakeGeometry.userSeatWindow.frame, serverFrame: FakeGeometry.userSeatWindow.frame,
            displayID: Self.builtIn, spaceID: Self.builtInHome)

        let sensing = FakeSensing()
        let placing = FakePlacing()
        // A later reading would put the same window somewhere else entirely.
        sensing.surfaces = [WindowSurface(
            reference: FakeGeometry.reference(frame: CGRect(x: 900, y: 500, width: 800, height: 600)),
            level: 0, isVisible: true)]
        let seat = makeSeat(sensing: sensing, placing: placing)
        seat.noteOrigins([FakeGeometry.identity(): first])
        _ = try await seat.adopt(FakeGeometry.userSeatWindow)

        #expect(seat.physicalOrigins[FakeGeometry.identity()] == first)
    }
}

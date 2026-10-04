//
//  FullScreenTransferTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing
import VirtualScreens
import WindowPlacement

/// MW-03's state machine, on the three fakes: a window in native macOS
/// fullscreen is taken out of it, moved onto the Virtual Display, and given
/// back. No display, no accessibility grant, nobody's window.
///
/// The rows assert the order of the writes and what survives each step, because
/// that is what a rollback needs and what a frame alone cannot say. What the
/// transitions cost is a measurement and lives in the Live tier and the report.
@MainActor
@Suite("Transferring a window out of native fullscreen")
struct FullScreenTransferTests {

    /// The rectangle the window server publishes while the window is in
    /// fullscreen: the whole visible frame of the physical display. It is also,
    /// exactly, what a maximised window publishes, which is why no row here
    /// classifies anything by its rectangle.
    static let fullScreenFrame = CGRect(x: 0, y: 33, width: 1512, height: 949)

    /// What the window measures once it has left fullscreen. Read after the
    /// exit and never remembered from before it.
    static let normalFrame = CGRect(x: 200, y: 190, width: 720, height: 592)

    static func fullScreenWindow(
        _ placing: FakePlacing,
        _ sensing: FakeSensing
    ) -> WindowReference {

        let window = FakeGeometry.reference(
            frame       : fullScreenFrame,
            windowNumber: FakeGeometry.userSeatWindow.windowNumber
        )
        placing.fullScreenStates[window.windowNumber] = .writable(true)
        placing.normalFrameAfterExit = normalFrame
        placing.bodyFrame = normalFrame
        // The window server's answer is driven, not decorated: this fake serves
        // the primary Window ID from `geometry`, so a row that wrote anywhere
        // else would confirm a move that never happened.
        sensing.geometry = window
        // A move takes the accessibility body with it, as it does on a real window: a return that
        // reads the body still at its normal frame would take the window as home and not move it.
        placing.onMove = { [unowned placing] origin in
            let moved = CGRect(origin: origin, size: normalFrame.size)
            placing.bodyFrame = moved
            sensing.geometry  = FakeGeometry.reference(
                frame       : moved,
                windowNumber: window.windowNumber
            )
        }
        return window
    }

    static func seat(
        _ sensing: FakeSensing,
        _ placing: FakePlacing,
        transfers: Bool = true,
        restores : Bool = false
    ) -> AgentSeat {
        let seat = makeSeat(sensing: sensing, placing: placing, sender: FakeSender())
        seat.transfersFullScreenWindows  = transfers
        seat.restoresFullScreenOnRelease = restores
        return seat
    }

    // MARK: The gate, which is the default

    @Test("a fullscreen window is refused by default, and nothing at all is written")
    func refusedUnlessTheExperimentIsOn() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        let seat    = Self.seat(sensing, placing, transfers: false)

        await #expect(throws: SessionFailure.fullScreenTransferDisabled(
            windowNumber: window.windowNumber
        )) {
            try await seat.adopt(window, platform: AppKitPlatform())
        }
        #expect(placing.fullScreenRequests.isEmpty, "the default path asked a window to leave fullscreen")
        #expect(placing.moves.isEmpty, "the default path wrote AXPosition on a fullscreen window")
        #expect(seat.adoptedWindows.isEmpty)
    }

    @Test("a window that is not in fullscreen is untouched by the experiment")
    func ordinaryWindowIsNotTouched() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat    = Self.seat(sensing, placing)

        _ = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())

        #expect(placing.fullScreenRequests.isEmpty)
        #expect(seat.adoptedWindows.count == 1)
        #expect(seat.adoptedWindows[0].wasFullScreen == false)
    }

    // MARK: Not supported, and said so

    @Test("a window whose AXFullScreen is read only is not supported and is left alone")
    func readOnlyAttributeIsNotSupported() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        placing.fullScreenStates[window.windowNumber] = .readOnly(true)
        let seat = Self.seat(sensing, placing)

        await #expect(throws: DisplayFailure.fullScreenNotSettable(
            windowNumber: window.windowNumber
        )) {
            try await seat.adopt(window, platform: AppKitPlatform())
        }
        #expect(placing.fullScreenRequests.isEmpty)
        #expect(placing.moves.isEmpty, "a window macOS will not let go of was moved anyway")
    }

    @Test("an unreadable AXFullScreen is not read as false")
    func unreadableAttributeIsNotFalse() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        placing.fullScreenStates[window.windowNumber] = .unreadable(.attributeUnsupported)
        // No exit was requested in this row, so moving must not substitute
        // the normal-size body that the fullscreen-exit fake usually supplies.
        placing.bodyFrame = window.frame
        placing.onMove = { origin in
            let moved = CGRect(origin: origin, size: window.frame.size)
            placing.bodyFrame = moved
            sensing.geometry = window.replacingFrame(moved)
        }
        let seat = Self.seat(sensing, placing)

        // Unreadable is not fullscreen either: the seat does not invent a state
        // it could not read, so the ordinary path runs and the window moves.
        _ = try await seat.adopt(window, platform: AppKitPlatform())
        #expect(placing.fullScreenRequests.isEmpty)
        #expect(seat.adoptedWindows[0].wasFullScreen == false)
        #expect(seat.session[window.windowNumber]?.operationalSize == window.frame.size)
    }

    @Test("an unreadable fullscreen attribute does not admit an unrequested size change")
    func anUnreadableAttributeDoesNotAuthorizeResizing() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window = Self.fullScreenWindow(placing, sensing)
        placing.fullScreenStates[window.windowNumber] = .unreadable(.attributeUnsupported)
        let seat = Self.seat(sensing, placing)

        await #expect(throws: DisplayFailure.self) {
            try await seat.adopt(window, platform: AppKitPlatform())
        }

        #expect(placing.fullScreenRequests.isEmpty)
        #expect(seat.adoptedWindows.isEmpty)
        #expect(seat.lastAdoptionFailure != nil)
    }

    // MARK: The Space gate

    @Test("a fullscreen window whose Space is still on screen is refused, not exited")
    func spaceStillOnScreenIsRefused() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        placing.spacesOnScreen = [window.windowNumber]
        let seat = Self.seat(sensing, placing)

        await #expect(throws: DisplayFailure.fullScreenSpaceStillOnScreen(
            windowNumber: window.windowNumber
        )) {
            try await seat.adopt(window, platform: AppKitPlatform())
        }
        #expect(placing.fullScreenRequests.isEmpty)
        #expect(placing.moves.isEmpty)
    }

    // MARK: The whole outward leg

    @Test("the exit comes first, the normal frame is read after it, and the move uses that frame")
    func exitThenMoveWithTheRereadFrame() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        let seat    = Self.seat(sensing, placing)

        let adopted = try await seat.adopt(window, platform: AppKitPlatform())

        #expect(placing.fullScreenRequests.map(\.wanted) == [false],
                "the seat asked for something other than exactly one exit")
        #expect(placing.moves.count == 1)

        // The centring is the normal frame's, never the fullscreen rectangle's.
        // Centring 1512 by 949 inside the virtual bounds puts the window
        // somewhere the confirmation would then refuse.
        let bounds = sensing.virtualDisplayBounds
        let expected = CGPoint(
            x: bounds.midX - Self.normalFrame.width  / 2,
            y: bounds.midY - Self.normalFrame.height / 2
        )
        #expect(placing.moves[0] == expected,
                "the move was centred on the fullscreen rectangle, not on the normal frame")

        // The three facts the return leg needs, all of them on the handle.
        #expect(adopted.wasFullScreen, "the window forgot it was ever in fullscreen")
        #expect(adopted.originalFrame.size == Self.normalFrame.size,
                "the original frame is the fullscreen rectangle instead of the normal one")
        #expect(adopted.originalFrame.origin == Self.normalFrame.origin)
    }

    // MARK: The return leg, and its two switches

    @Test("a release leaves fullscreen off by default and returns the window to its normal frame")
    func releaseDoesNotRestoreFullScreenByDefault() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        let seat    = Self.seat(sensing, placing)

        let adopted = try await seat.adopt(window, platform: AppKitPlatform())
        placing.fullScreenRequests.removeAll()

        let outcome = await seat.release(adopted)

        #expect(outcome == .returned)
        #expect(placing.moves.last == Self.normalFrame.origin,
                "the window was not put back at the normal frame read after the exit")
        #expect(placing.fullScreenRequests.isEmpty,
                Comment(rawValue: "the release put the window back into fullscreen without being "
                    + "asked, which takes the person's focus every time"))
        #expect(placing.stages == 0,
                "the return raised the window over the person's own windows")
    }

    @Test("with the second switch on, and only then, the release asks for fullscreen back")
    func releaseRestoresFullScreenWhenAsked() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        let seat    = Self.seat(sensing, placing, restores: true)

        let adopted = try await seat.adopt(window, platform: AppKitPlatform())
        placing.fullScreenRequests.removeAll()

        let outcome = await seat.release(adopted)

        #expect(outcome == .returned)
        #expect(placing.fullScreenRequests.map(\.wanted) == [true],
                "the window did not go back into the state it was found in")
    }

    @Test("assignment release passes its residual deadline to a late fullscreen return")
    func assignmentReleaseUsesResidualBudgetForFullScreenReturn() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        let seat    = Self.seat(sensing, placing, restores: true)

        _ = try await seat.adopt(window, platform: AppKitPlatform())
        placing.fullScreenRequests.removeAll()

        // The two return readings each spend the release's bounded cadence
        // before the original fullscreen state can be restored. The fake sees
        // the actual residual passed across the protocol boundary.
        let report = await seat.releaseAssignment(within: .seconds(1))

        #expect(report.outcome == .released)
        #expect(report.windows[window.windowNumber] == .returned)
        let residual = try #require(placing.fullScreenAwaitBudgets.last)
        #expect(residual > .zero)
        #expect(residual < .milliseconds(900),
                "the fullscreen collaborator must not receive a fresh release budget")
    }

    @Test("a window that was never in fullscreen is not put into one by the restore switch")
    func restoreSwitchOnlyAppliesToWhatWasFound() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat    = Self.seat(sensing, placing, restores: true)

        let adopted = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.fullScreenRequests.removeAll()

        _ = await seat.release(adopted)
        #expect(placing.fullScreenRequests.isEmpty)
    }

    @Test("a restore that fails still reports the return that did happen")
    func failedRestoreDoesNotUndoTheReturn() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        let seat    = Self.seat(sensing, placing, restores: true)

        let adopted = try await seat.adopt(window, platform: AppKitPlatform())
        placing.fullScreenAwaitError = DisplayFailure.fullScreenTransitionNotObserved(
            windowNumber: window.windowNumber, wanted: true, lastFrame: nil
        )

        let outcome = await seat.release(adopted)
        #expect(outcome == .returned,
                "the window is home and usable, and only its fullscreen state is missing")
    }

    // MARK: The watcher, MW-02's half of this

    /// A detected window in fullscreen, offered to a seat that is already
    /// following, with the fullscreen state on it.
    static func offerFullScreen(
        _ windowNumber: Int,
        to sensing    : FakeSensing,
        _ placing     : FakePlacing,
        state         : WindowRelocator.FullScreenReading
    ) -> WindowReference {
        let window = AppWindowFollowTests.offer(
            windowNumber,
            to  : sensing,
            placing,
            frame: fullScreenFrame,
            body : fullScreenFrame
        )
        placing.fullScreenStates[windowNumber] = state
        return window
    }

    @Test("the watcher names the three fullscreen answers instead of calling them a refused move")
    func theWatcherNamesTheFullScreenAnswers() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await AppWindowFollowTests.followingSeat(
            sensing: sensing, placing: placing
        )
        let log = MultiWindowTests.EventLog(seat)

        // Off by default, which is what the ordinary watcher answers today.
        let disabled = Self.offerFullScreen(
            AppWindowFollowTests.secondWindowNumber, to: sensing, placing, state: .writable(true)
        )
        await AppWindowFollowTests.pass(seat, 2)
        await log.drain()
        #expect(AppWindowFollowTests.refusals(log).contains {
            $0.0 == disabled.windowNumber && $0.1 == .fullScreenTransferDisabled
        })
        #expect(placing.fullScreenRequests.isEmpty)

        // Turned on, a window macOS will not let go of is not supported.
        seat.transfersFullScreenWindows = true
        let readOnly = Self.offerFullScreen(
            AppWindowFollowTests.thirdWindowNumber, to: sensing, placing, state: .readOnly(true)
        )
        await AppWindowFollowTests.pass(seat, 2)
        await log.drain()
        #expect(AppWindowFollowTests.refusals(log).contains {
            $0.0 == readOnly.windowNumber && $0.1 == .fullScreenNotSupported
        })
        #expect(placing.fullScreenRequests.isEmpty,
                "a window whose attribute is read only was asked to leave fullscreen anyway")
        #expect(seat.adoptedWindows.count == 1, "a refused window was adopted")
    }

    @Test("a fullscreen window whose Space is on screen costs no attempt and is taken later")
    func theSpaceGateIsAComeBackLater() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await AppWindowFollowTests.followingSeat(
            sensing: sensing, placing: placing
        )
        seat.transfersFullScreenWindows = true
        let log = MultiWindowTests.EventLog(seat)

        let candidate = Self.offerFullScreen(
            AppWindowFollowTests.secondWindowNumber, to: sensing, placing, state: .writable(true)
        )
        placing.spacesOnScreen = [candidate.windowNumber]
        placing.normalFrameAfterExit = Self.normalFrame

        // Six passes, twice the attempt budget. Spending one per pass would
        // have exhausted it and refused this window for good, a third of a
        // second before the person looked away.
        await AppWindowFollowTests.pass(seat, 6)
        await log.drain()
        #expect(AppWindowFollowTests.refusals(log).isEmpty,
                "a moment that is wrong was reported as a window that cannot be moved")
        #expect(seat.adoptedWindows.count == 1)

        // The person looks away and nothing else changes.
        placing.spacesOnScreen = []
        await AppWindowFollowTests.pass(seat, 3)
        #expect(seat.adoptedWindows.count == 2,
                "the window was never taken once its Space had gone")
        #expect(placing.fullScreenRequests.map(\.wanted) == [false])
    }

    // MARK: Cancellation and rollback

    @Test("a move refused after the exit rolls the window back to its normal frame")
    func rollbackAfterTheExit() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        let seat    = Self.seat(sensing, placing)

        placing.moveError = DisplayFailure.attributeNotSettable("AXPosition")

        await #expect(throws: (any Error).self) {
            try await seat.adopt(window, platform: AppKitPlatform())
        }

        let failure = try #require(seat.lastAdoptionFailure)
        #expect(failure.window.windowNumber == window.windowNumber)
        #expect(seat.adoptedWindows.isEmpty)
        // The exit happened and is not undone by default: putting the window
        // back into fullscreen takes the focus, and a failure is the worst
        // moment to take it.
        #expect(placing.fullScreenRequests.map(\.wanted) == [false])
    }

    @Test("a transition that never becomes observable is a refusal, not a window half moved")
    func exitThatIsNeverObservedRefuses() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let window  = Self.fullScreenWindow(placing, sensing)
        let seat    = Self.seat(sensing, placing)

        placing.fullScreenAwaitError = DisplayFailure.fullScreenTransitionNotObserved(
            windowNumber: window.windowNumber, wanted: false, lastFrame: Self.fullScreenFrame
        )

        await #expect(throws: DisplayFailure.fullScreenTransitionNotObserved(
            windowNumber: window.windowNumber, wanted: false, lastFrame: Self.fullScreenFrame
        )) {
            try await seat.adopt(window, platform: AppKitPlatform())
        }
        #expect(placing.moves.isEmpty, "a window whose transition was never seen was moved anyway")
        #expect(seat.adoptedWindows.isEmpty)
    }
}

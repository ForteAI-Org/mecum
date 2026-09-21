//
//  AppWindowInventoryTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The diffing half of following an application's windows, with nothing
/// attached: no display, no window server, no accessibility grant. Every
/// reading is handed in, which is the point of the type being a value.
@Suite("The window inventory")
struct AppWindowInventoryTests {

    static let menuLevel = 101

    static let physical = CGRect(x: 100, y: 100, width: 800, height: 600)
    static let virtual  = FakeGeometry.virtual

    static var driven: Set<ProcessIdentity> {
        [FakeGeometry.identity().process]
    }

    static func surface(
        _ windowNumber: Int,
        frame         : CGRect = physical,
        level         : Int    = 0,
        isVisible     : Bool   = true,
        lifetime      : UInt32 = 1,
        processID     : Int32  = FakeGeometry.targetPID
    ) -> WindowSurface {
        WindowSurface(
            reference: FakeGeometry.reference(
                frame       : frame,
                processID   : processID,
                windowNumber: windowNumber,
                lifetime    : lifetime
            ),
            level    : level,
            isVisible: isVisible
        )
    }

    /// Folds readings in one after another and answers the last batch of
    /// changes, which is what every row here asserts on.
    @discardableResult
    static func fold(
        _ inventory: inout AppWindowInventory,
        _ readings : [[WindowSurface]?],
        adopted    : Set<Int> = [],
        processes  : Set<ProcessIdentity>? = nil
    ) -> [AppWindowChange] {
        var last: [AppWindowChange] = []
        for reading in readings {
            last = inventory.changes(
                surfaces : reading,
                processes: processes ?? driven,
                adopted  : adopted,
                within   : virtual,
                menuLevel: menuLevel
            )
        }
        return last
    }

    // MARK: The baseline

    @Test("the first reading is a baseline and transfers nothing")
    func firstReadingIsABaseline() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700), Self.surface(701)]

        #expect(Self.fold(&inventory, [there]).isEmpty)
        #expect(Self.fold(&inventory, [there]).isEmpty, "and it stays a baseline one pass later")
        #expect(inventory.isPrimed)
    }

    @Test("the baseline is taken when the seat starts driving, never at the first pass")
    func theBaselineIsTakenOnDemand() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700), Self.surface(701)]
        inventory.baseline(surfaces: there, processes: Self.driven)

        #expect(inventory.isPrimed)
        #expect(Self.fold(&inventory, [there, there]).isEmpty)

        // A window that arrived after the baseline is a candidate, and a second
        // baseline does not quietly turn it into furniture.
        let arriving = Self.surface(702)
        let seenOnce = [Self.surface(700), arriving]
        #expect(Self.fold(&inventory, [seenOnce]).isEmpty)
        inventory.baseline(surfaces: seenOnce, processes: Self.driven)
        #expect(Self.fold(&inventory, [seenOnce]) == [.appeared(arriving.reference)])
    }

    @Test("a window already on the person's display that moves is still not transferred")
    func aPreexistingWindowThatMovesStaysPut() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let moved = Self.surface(700, frame: Self.physical.offsetBy(dx: 300, dy: 40))
        #expect(Self.fold(&inventory, [[moved], [moved]]).isEmpty)
    }

    // MARK: A window that arrives

    @Test("a new window is a candidate only once two readings agree on it")
    func newWindowNeedsTwoAgreeingReadings() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let arriving = Self.surface(701)
        #expect(Self.fold(&inventory, [[Self.surface(700), arriving]]).isEmpty,
                "one reading of a window whose geometry has not settled is not evidence")
        #expect(inventory.hasPendingCandidate)

        let changes = Self.fold(&inventory, [[Self.surface(700), arriving]])
        #expect(changes == [.appeared(arriving.reference)])
        #expect(!inventory.hasPendingCandidate)
    }

    @Test("a window whose frame is still moving is not acted on")
    func aWindowStillSettlingIsNotACandidate() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let first  = Self.surface(701, frame: CGRect(x: 100, y: 100, width: 10, height: 10))
        let second = Self.surface(701, frame: Self.physical)
        #expect(Self.fold(&inventory, [[first], [second]]).isEmpty)
        #expect(inventory.hasPendingCandidate)
        #expect(Self.fold(&inventory, [[second]]) == [.appeared(second.reference)])
    }

    @Test("a window that went away and came back is a reappearance and not a new window")
    func aWindowThatComesBack() {
        var inventory = AppWindowInventory()
        let window    = Self.surface(701)
        Self.fold(&inventory, [[Self.surface(700), window]])

        // Out of the on-screen list, then back at the same frame.
        Self.fold(&inventory, [[Self.surface(700)]])
        let changes = Self.fold(&inventory, [
            [Self.surface(700), window],
            [Self.surface(700), window],
        ])
        #expect(changes == [.reappeared(window.reference)])
    }

    @Test("two windows arriving in the same reading are both answered")
    func simultaneousArrivals() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let a = Self.surface(701)
        let b = Self.surface(702, frame: Self.physical.offsetBy(dx: 40, dy: 40))
        let changes = Self.fold(&inventory, [[a, b], [a, b]])
        #expect(Set(changes.map(Self.windowNumber)) == [701, 702])
    }

    // MARK: What is never a candidate

    @Test("a contextual menu, an invisible surface and another application are all left alone")
    func surfacesThatAreNotCandidates() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let menu      = Self.surface(701, level: Self.menuLevel)
        let invisible = Self.surface(702, isVisible: false)
        let stranger  = Self.surface(703, processID: FakeGeometry.userPID)
        let reading   = [Self.surface(700), menu, invisible, stranger]

        #expect(Self.fold(&inventory, [reading, reading]).isEmpty)
    }

    @Test("a PID reused after the application terminated inherits nothing")
    func aReusedProcessIDInheritsNothing() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        // Same PID, a different process lifetime: another application that
        // happened to be handed the number the driven one left behind.
        let successor = Self.surface(701, lifetime: 9)
        #expect(Self.fold(&inventory, [[successor], [successor]]).isEmpty)
    }

    @Test("a contextual menu that opens inside the virtual display is still left alone")
    func aMenuInsideTheDisplayIsNotACandidate() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        // The one surface that opens inside the seat by design: `useContextMenu`
        // owns it whole and a second owner adopting it loses the tracking loop.
        let menu    = Self.surface(701, frame: FakeGeometry.adoptedWindow.frame, level: Self.menuLevel)
        let reading = [Self.surface(700), menu]

        #expect(Self.fold(&inventory, [reading, reading]).isEmpty)
    }

    @Test("a window already inside the virtual display at the baseline is still never taken")
    func aBaselinedWindowInsideTheDisplayIsNeverTaken() {
        var inventory = AppWindowInventory()
        let inside    = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        inventory.baseline(surfaces: [inside], processes: Self.driven)

        #expect(Self.fold(&inventory, [[inside], [inside]]).isEmpty,
                "everything present when the seat took control is the person's")
    }

    // MARK: A window born inside the seat

    @Test("a window that appears inside the virtual display is offered for ownership, not for a move")
    func aWindowBornInsideTheDisplay() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        // Where macOS puts a new window: next to the application's active one,
        // which is the window the agent is working in, inside the seat.
        let inside  = Self.surface(701, frame: FakeGeometry.adoptedWindow.frame)
        let reading = [Self.surface(700), inside]

        #expect(Self.fold(&inventory, [reading]).isEmpty, "one reading is still a sighting")
        #expect(inventory.hasPendingCandidate)
        #expect(Self.fold(&inventory, [reading]) == [.appearedInVirtualDisplay(inside.reference)])

        // Nothing was moved, so the whole budget is still there for the day the
        // window does leave the display.
        for attempt in 1...AppWindowInventory.maximumAttempts {
            let allowed = inventory.mayAttempt(701)
            #expect(allowed, "attempt \(attempt) was spent on a window that needed no transfer")
        }
    }

    @Test("a window that appears outside the virtual display is still a transfer")
    func aWindowBornOutsideIsStillATransfer() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let outside = Self.surface(701, frame: Self.physical.offsetBy(dx: 20, dy: 20))
        let reading = [Self.surface(700), outside]
        #expect(Self.fold(&inventory, [reading, reading]) == [.appeared(outside.reference)])
    }

    @Test("a window the seat already holds is judged by where it is, never offered again")
    func aHeldWindowInsideIsNotOfferedAgain() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)

        #expect(Self.fold(&inventory, [[home], [home], [home]], adopted: [700]).isEmpty)
    }

    // MARK: The windows the seat holds

    @Test("a held window that leaves the display is reported once two readings agree")
    func heldWindowThatLeaves() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        Self.fold(&inventory, [[home]], adopted: [700])
        #expect(Self.fold(&inventory, [[home]], adopted: [700]).isEmpty)

        // The same rule as every other surface: one reading is a sighting.
        let left = Self.surface(700)
        #expect(Self.fold(&inventory, [[left]], adopted: [700]).isEmpty)
        #expect(inventory.hasPendingCandidate, "and it is worth looking again soon")
        #expect(Self.fold(&inventory, [[left]], adopted: [700])
            == [.leftVirtualDisplay(left.reference)])
    }

    @Test("a single frame outside the display reports nothing and costs no attempt")
    func oneStaleFrameIsNotAnEscape() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        Self.fold(&inventory, [[home]], adopted: [700])

        // What a Qt target was measured publishing: one frame outside the
        // display, the next one back where the window really is.
        let stale = Self.surface(700, frame: CGRect(x: 4032, y: 2390, width: 1345, height: 949))
        #expect(Self.fold(&inventory, [[stale], [home]], adopted: [700]).isEmpty)

        for attempt in 1...AppWindowInventory.maximumAttempts {
            let allowed = inventory.mayAttempt(700)
            #expect(allowed, "attempt \(attempt) was spent on an escape that never happened")
        }
    }

    @Test("a held window that comes back under control gets its attempts back")
    func aReturnedWindowStartsFromAFullBudget() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        let left      = Self.surface(700)
        Self.fold(&inventory, [[home]], adopted: [700])
        Self.fold(&inventory, [[left], [left]], adopted: [700])

        for _ in 1...AppWindowInventory.maximumAttempts { _ = inventory.mayAttempt(700) }
        let exhausted = inventory.mayAttempt(700)
        #expect(!exhausted)

        // Two agreeing readings back inside the display, which is the window
        // under control again and not a guess about it.
        Self.fold(&inventory, [[home], [home]], adopted: [700])
        let afterReturn = inventory.mayAttempt(700)
        #expect(afterReturn, "a later escape has to be answerable")
    }

    @Test("a held window missing from the reading is reported once, not at every pass")
    func heldWindowThatVanishes() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        Self.fold(&inventory, [[home]], adopted: [700])

        #expect(Self.fold(&inventory, [[]], adopted: [700]) == [.vanished(windowNumber: 700)])
        #expect(Self.fold(&inventory, [[]], adopted: [700]).isEmpty)
    }

    @Test("a reading that failed changes nothing at all")
    func anUnknownReadingIsNotAnEmptyDesktop() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        Self.fold(&inventory, [[home]], adopted: [700])

        let unknown: [WindowSurface]? = nil
        #expect(Self.fold(&inventory, [unknown], adopted: [700]).isEmpty,
                "an unreadable window server is unknown, never a desktop with nothing on it")

        // And the window is still known afterwards: the failed reading did not
        // forget it, so it is not a new window when the next reading succeeds.
        #expect(Self.fold(&inventory, [[home]], adopted: [700]).isEmpty)
    }

    // MARK: The attempt budget

    @Test("the attempts on one window are bounded and a transferred window starts again")
    func attemptsAreBounded() {
        var inventory = AppWindowInventory()
        for attempt in 1...AppWindowInventory.maximumAttempts {
            let allowed = inventory.mayAttempt(701)
            #expect(allowed, "attempt \(attempt) is inside the budget")
        }
        let exhausted = inventory.mayAttempt(701)
        #expect(!exhausted)

        let otherWindow = inventory.mayAttempt(702)
        #expect(otherWindow, "the budget is per window and not per seat")

        inventory.clearAttempts(of: 701)
        let afterTransfer = inventory.mayAttempt(701)
        #expect(afterTransfer)
    }

    private static func windowNumber(_ change: AppWindowChange) -> Int {
        switch change {
            case .appeared(let window), .reappeared(let window),
                 .appearedInVirtualDisplay(let window), .leftVirtualDisplay(let window):
                window.windowNumber
            case .vanished(let windowNumber):
                windowNumber
        }
    }
}

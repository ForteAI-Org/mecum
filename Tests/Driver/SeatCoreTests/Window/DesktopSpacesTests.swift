//
//  DesktopSpacesTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// Which desktop a returning window is owed, and what a reading of its desktops
/// proves. The layout is written down: no window server is asked anything.
@Suite("The desktop a window returns to")
struct DesktopSpacesTests {

    /// The reference machine: the built-in display with two desktops and the
    /// second one shown, and an external display with two desktops, the first
    /// one shown.
    static let layout = DesktopLayout(displays: [
        .init(displayID: 1, spaces: [2419, 1],    current: 1),
        .init(displayID: 3, spaces: [2079, 2313], current: 2079),
    ])

    // MARK: The target

    @Test("the original desktop is the target while a display still lists it")
    func originalDesktopWins() {
        #expect(
            SpaceReturn.target(originalSpace: 2079, originalDisplay: 3, in: Self.layout)
                == .original(2079)
        )
        // Even a desktop that is not shown: the window is owed its own.
        #expect(
            SpaceReturn.target(originalSpace: 2419, originalDisplay: 1, in: Self.layout)
                == .original(2419)
        )
    }

    @Test("a closed desktop falls back to the one its display shows now")
    func goneDesktopFallsBackToTheCurrentOne() {
        #expect(
            SpaceReturn.target(originalSpace: 9999, originalDisplay: 3, in: Self.layout)
                == .currentOfOriginalDisplay(2079)
        )
        #expect(
            SpaceReturn.target(originalSpace: 9999, originalDisplay: 1, in: Self.layout)
                == .currentOfOriginalDisplay(1)
        )
    }

    @Test("a target that cannot be proved is unknown, never invented")
    func unprovableTargetIsUnknown() {
        // The desktop was never read: no claim about which one is owed.
        #expect(SpaceReturn.target(originalSpace: nil, originalDisplay: 1, in: Self.layout) == .unknown)
        // The layout is unreadable.
        #expect(SpaceReturn.target(originalSpace: 2079, originalDisplay: 3, in: nil) == .unknown)
        // The desktop is gone and so is its display.
        #expect(SpaceReturn.target(originalSpace: 9999, originalDisplay: 8, in: Self.layout) == .unknown)
        #expect(SpaceReturn.target(originalSpace: 9999, originalDisplay: nil, in: Self.layout) == .unknown)
    }

    // MARK: The verdict

    @Test("a window on the owed desktop is in place, on any other it is not")
    func verdictFollowsTheTarget() {
        #expect(SpaceReturn.verdict(windowSpaces: [2079], target: .original(2079)) == .inPlace)
        #expect(SpaceReturn.verdict(windowSpaces: [2419], target: .original(2079)) == .otherSpace)
        #expect(SpaceReturn.verdict(windowSpaces: [2079], target: .currentOfOriginalDisplay(2079)) == .inPlace)
        #expect(SpaceReturn.verdict(windowSpaces: [2313], target: .currentOfOriginalDisplay(2079)) == .otherSpace)
    }

    @Test("a window assigned to several desktops is in place when the owed one is among them")
    func severalDesktops() {
        #expect(SpaceReturn.verdict(windowSpaces: [2419, 1], target: .original(1)) == .inPlace)
        #expect(SpaceReturn.verdict(windowSpaces: [2419, 1], target: .original(2079)) == .otherSpace)
    }

    @Test("a missing or empty reading, or an unknown target, proves nothing")
    func unreadVerdictIsUnknown() {
        #expect(SpaceReturn.verdict(windowSpaces: nil, target: .original(1)) == .unknown)
        #expect(SpaceReturn.verdict(windowSpaces: [], target: .original(1)) == .unknown)
        #expect(SpaceReturn.verdict(windowSpaces: [1], target: .unknown) == .unknown)
    }

    // MARK: A window on another desktop

    @Test("a window whose every desktop is closed to view is on another desktop")
    func windowOnAnotherDesktop() {
        // Desktop 1 of the built-in display, with Desktop 2 shown.
        #expect(SpaceReturn.isOnAnotherDesktop(windowSpaces: [2419], in: Self.layout))
        #expect(SpaceReturn.isOnAnotherDesktop(windowSpaces: [2313], in: Self.layout))
    }

    @Test("a window on a shown desktop, or on several one of which is shown, is not")
    func windowOnAShownDesktop() {
        #expect(!SpaceReturn.isOnAnotherDesktop(windowSpaces: [1], in: Self.layout))
        #expect(!SpaceReturn.isOnAnotherDesktop(windowSpaces: [2079], in: Self.layout))
        #expect(!SpaceReturn.isOnAnotherDesktop(windowSpaces: [2419, 1], in: Self.layout))
    }

    @Test("no claim is made without evidence")
    func noEvidenceNoClaim() {
        #expect(!SpaceReturn.isOnAnotherDesktop(windowSpaces: nil, in: Self.layout))
        #expect(!SpaceReturn.isOnAnotherDesktop(windowSpaces: [], in: Self.layout))
        #expect(!SpaceReturn.isOnAnotherDesktop(windowSpaces: [2419], in: nil))
        // A desktop no display lists is not a desktop the person can switch to.
        #expect(!SpaceReturn.isOnAnotherDesktop(windowSpaces: [777], in: Self.layout))
    }
}

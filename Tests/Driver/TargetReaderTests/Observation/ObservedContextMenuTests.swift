//
//  ObservedContextMenuTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import CoreGraphics
import Foundation
import Testing

@testable import TargetReader

/// The shape of a contextual menu reading. What is asserted here is the
/// distinction the type exists for, because a caller that cannot tell "no menu"
/// from "a menu nobody can read" plans wrongly on both.
@Suite("The shape of a contextual menu reading")
struct ObservedContextMenuTests {

    @Test("an unreadable menu is not an empty one, and the two are not equal")
    func unreadableIsNotEmpty() {
        let empty      = ObservedContextMenu.items([])
        let unreadable = ObservedContextMenu.drawnOutsideTheAccessibilityTree(
            frame: CGRect(x: 10, y: 20, width: 201, height: 377)
        )

        #expect(empty != unreadable)
        #expect(empty != .notOpen)
        #expect(unreadable != .notOpen)
    }

    /// The Chromium answer carries the one thing the caller can still use.
    @Test("the unreadable case carries the rectangle, which is all there is of it")
    func unreadableCarriesTheRectangle() throws {
        let frame = CGRect(x: 815, y: 457, width: 201, height: 377)

        guard case .drawnOutsideTheAccessibilityTree(let reported) =
            ObservedContextMenu.drawnOutsideTheAccessibilityTree(frame: frame)
        else {
            Issue.record("the case did not carry its frame")
            return
        }
        #expect(reported == frame)
    }

    /// A separator answers no title and no position, and it stays in the list:
    /// an index into these items is an index into what the target draws.
    @Test("a separator is kept, so an index means the same thing on both sides")
    func separatorsAreKept() {
        let items = [
            ObservedMenuItem(
                title: "Copy", isEnabled: true, isSelected: false, hasSubmenu: false,
                frame: CGRect(x: 0, y: 0, width: 100, height: 20)
            ),
            ObservedMenuItem(
                title: "", isEnabled: false, isSelected: false, hasSubmenu: false, frame: nil
            ),
            ObservedMenuItem(
                title: "Services", isEnabled: true, isSelected: false, hasSubmenu: true,
                frame: CGRect(x: 0, y: 40, width: 100, height: 20)
            ),
        ]

        #expect(items.count == 3)
        #expect(items[1].frame == nil)
        #expect(items[2].hasSubmenu, "a submenu is not a choice, and the caller has to know")
    }
}

/// Reaching a menu that is not under the window element, which is the shape
/// Finder was measured in. The walk itself is pure, so it can be asserted here;
/// what the system answers at a point cannot be, and is not claimed.
@Suite("Reaching a menu from the point it is drawn at")
struct ContextMenuPositionWalkTests {

    /// Measured on Finder: the point at the menu's centre hits an `AXMenuItem`
    /// whose parent is the `AXMenu`, so one hop is the ordinary case.
    @Test("the walk climbs from the row drawn at the point to the menu holding it")
    func climbsToTheMenu() {
        let roles   = [1: "AXMenuItem", 2: "AXMenu", 3: "AXApplication"]
        let parents = [1: 2, 2: 3]

        let found = WindowReader.enclosingMenu(
            from   : 1,
            ownedBy: 487,
            role   : { roles[$0] },
            owner  : { _ in 487 },
            parent : { parents[$0] }
        )

        #expect(found == 2)
    }

    /// A point can be covered by another application's window, and reading the
    /// menu found there would click an item in a process nobody named.
    @Test("a menu belonging to another process is refused, not read")
    func refusesAnotherProcess() {
        let roles   = [1: "AXMenuItem", 2: "AXMenu"]
        let parents = [1: 2]

        let foreign = WindowReader.enclosingMenu(
            from   : 1,
            ownedBy: 487,
            role   : { roles[$0] },
            owner  : { _ in 903 },
            parent : { parents[$0] }
        )
        let own = WindowReader.enclosingMenu(
            from   : 1,
            ownedBy: 487,
            role   : { roles[$0] },
            owner  : { _ in 487 },
            parent : { parents[$0] }
        )

        #expect(foreign == nil, "the same tree is refused only because the owner differs")
        #expect(own == 2)
    }

    /// An element that answers no process at all is not the target's either.
    @Test("an element that cannot say who owns it is refused")
    func refusesUnknownOwner() {
        let found = WindowReader.enclosingMenu(
            from   : 1,
            ownedBy: 487,
            role   : { _ in "AXMenu" },
            owner  : { _ in nil },
            parent : { _ in nil }
        )

        #expect(found == nil)
    }

    /// Nothing promises the hit element sits under a menu, and a parent chain
    /// can be long or circular, so the climb ends on its own.
    @Test("the climb is bounded, so a point under something else ends rather than walks")
    func boundedClimb() {
        var elementsRead = 0

        let found = WindowReader.enclosingMenu(
            from       : 0,
            ownedBy    : 487,
            parentLimit: 3,
            role       : { _ in elementsRead += 1; return "AXGroup" },
            owner      : { _ in 487 },
            parent     : { $0 + 1 }
        )

        #expect(found == nil)
        #expect(elementsRead == 4, "the element drawn at the point, and three parents above it")
    }
}

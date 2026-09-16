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

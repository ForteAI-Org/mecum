//
//  ContextMenuChoiceTests.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import CoreGraphics
import TargetReader
import Testing
@testable import SeatBroker

/// The choice on its own: a reading of a menu and a wanted title in, a point
/// or a refusal out. No seat, no interaction, no click.
@Suite("Choosing a contextual menu item by title")
struct ContextMenuChoiceTests {

    private static func item(_ title: String, enabled: Bool = true, submenu: Bool = false,
                             frame: CGRect? = CGRect(x: 100, y: 200, width: 180, height: 22)) -> ObservedMenuItem {
        ObservedMenuItem(title: title, isEnabled: enabled, isSelected: false,
                         hasSubmenu: submenu, frame: frame)
    }

    /// The point is the centre of the row's own rectangle, which is the only
    /// part of an item a click can be aimed at.
    @Test func exactTitleAnswersTheCentreOfItsRow() {
        let menu = ObservedContextMenu.items([
            Self.item("Apri"),
            Self.item("Copia", frame: CGRect(x: 100, y: 240, width: 180, height: 22)),
        ])
        #expect(ContextMenuChoice.choosing("Copia", in: menu) == .click(CGPoint(x: 190, y: 251)))
    }

    /// Localised titles are what the target draws, so the capital a planner
    /// wrote is not a different item. An accent typed flat is not either.
    @Test func caseAndAccentsDoNotDecideTheMatch() {
        let menu = ObservedContextMenu.items([Self.item("Più grande")])
        #expect(ContextMenuChoice.choosing("piu grande", in: menu) == .click(CGPoint(x: 190, y: 211)))
    }

    /// A title macOS prints with an ellipsis is the same command the planner
    /// named without one.
    @Test func aTrailingEllipsisIsNotPartOfTheTitle() {
        let menu = ObservedContextMenu.items([Self.item("Salva con nome…")])
        #expect(ContextMenuChoice.choosing("Salva con nome", in: menu) == .click(CGPoint(x: 190, y: 211)))
    }

    /// A near miss is refused rather than widened: "Copia" and "Copia
    /// indirizzo" are two commands and choosing the wrong one runs it.
    @Test func aLongerTitleIsNotTheWantedOne() {
        let menu = ObservedContextMenu.items([Self.item("Copia indirizzo")])
        guard case .refused(let reason) = ContextMenuChoice.choosing("Copia", in: menu) else {
            Issue.record("a substring is not a match")
            return
        }
        #expect(reason.contains("Copia indirizzo"))
    }

    @Test func aDisabledItemIsRefusedAndSaysSo() {
        let menu = ObservedContextMenu.items([Self.item("Incolla", enabled: false)])
        guard case .refused(let reason) = ContextMenuChoice.choosing("Incolla", in: menu) else {
            Issue.record("a disabled item is not a choice")
            return
        }
        #expect(reason.contains("Incolla"))
        #expect(reason.lowercased().contains("disabled"))
    }

    @Test func anItemWithASubmenuIsRefusedAndSaysSo() {
        let menu = ObservedContextMenu.items([Self.item("Apri con", submenu: true)])
        guard case .refused(let reason) = ContextMenuChoice.choosing("Apri con", in: menu) else {
            Issue.record("a submenu is not a choice")
            return
        }
        #expect(reason.contains("Apri con"))
        #expect(reason.lowercased().contains("submenu"))
    }

    /// The history line has to carry what the menu did offer, or the planner
    /// asks for the same absent title again.
    @Test func aTitleThatMatchesNothingNamesWhatWasThere() {
        let menu = ObservedContextMenu.items([
            Self.item("Apri"), Self.item(""), Self.item("Copia"), Self.item("Rinomina"),
        ])
        guard case .refused(let reason) = ContextMenuChoice.choosing("Paste", in: menu) else {
            Issue.record("an absent title is not a choice")
            return
        }
        #expect(reason.contains("Paste"))
        #expect(reason.contains("Apri"))
        #expect(reason.contains("Copia"))
        #expect(reason.contains("Rinomina"))
    }

    /// The Chromium answer. The rectangle is known and it is never turned into
    /// a click: the items inside it were never read.
    @Test func aMenuOutsideTheTreeIsNeverAPoint() {
        let menu = ObservedContextMenu.drawnOutsideTheAccessibilityTree(
            frame: CGRect(x: 10, y: 10, width: 200, height: 300))
        guard case .refused(let reason) = ContextMenuChoice.choosing("Copia", in: menu) else {
            Issue.record("an unreadable menu answers no point")
            return
        }
        #expect(reason.contains("cannot be read by title"))
    }

    @Test func aMenuThatNeverOpenedHasItsOwnReason() {
        guard case .refused(let reason) = ContextMenuChoice.choosing("Copia", in: .notOpen) else {
            Issue.record("nothing opened is not a choice")
            return
        }
        #expect(reason.lowercased().contains("no contextual menu"))
    }

    /// A row the target lists without a position cannot be aimed at, and a
    /// guessed coordinate would be a click somewhere nobody looked.
    @Test func anItemWithoutAFrameIsRefused() {
        let menu = ObservedContextMenu.items([Self.item("Copia", frame: nil)])
        guard case .refused(let reason) = ContextMenuChoice.choosing("Copia", in: menu) else {
            Issue.record("an item with no rectangle is not a choice")
            return
        }
        #expect(reason.contains("Copia"))
    }
}

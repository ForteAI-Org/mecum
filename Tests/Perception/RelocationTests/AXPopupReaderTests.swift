import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

/// The PURE half of popup AX enumeration (ticket 06): which menu rows are selectable, which are
/// painted on screen, what the scene says about the ones that aren't, and the match rule that guards
/// a press. No AX, no screen — these run anywhere.
final class AXPopupReaderTests: XCTestCase {
    /// A menu as macOS reports one: a visible first page, a separator, and rows scrolled out of view
    /// (no frame at all) — the TextEdit font-menu shape that made `act(target:"Helvetica")` miss.
    private let popup = CGRect(x: 400, y: 200, width: 220, height: 120)

    private func item(_ title: String, y: CGFloat?, order: Int, enabled: Bool = true,
                      checked: Bool = false, submenu: Bool = false) -> AXPopupReader.MenuItem {
        AXPopupReader.MenuItem(title: title,
                               frameGlobalPt: y.map { CGRect(x: 404, y: $0, width: 212, height: 20) },
                               enabled: enabled, checked: checked, hasSubmenu: submenu, order: order)
    }

    // MARK: selectable rows

    func testSeparatorsAndDecorationAreNotSelectable() {
        XCTAssertFalse(AXPopupReader.isSelectable(title: ""))
        XCTAssertFalse(AXPopupReader.isSelectable(title: "  "))
        XCTAssertFalse(AXPopupReader.isSelectable(title: "———"))     // an NSMenu separator's glyph row
        XCTAssertTrue(AXPopupReader.isSelectable(title: "Helvetica"))
        XCTAssertTrue(AXPopupReader.isSelectable(title: "1920 x 1080 HD"))
        XCTAssertFalse(AXPopupReader.isSelectable(title: String(repeating: "x", count: 65)))
    }

    // MARK: painted vs scrolled out

    func testOnViewNeedsAFrameInsideTheOpenPopup() {
        XCTAssertTrue(AXPopupReader.isOnView(item("Arial", y: 260, order: 0), popup: popup))
        // Below the menu's painted box — a long menu's scrolled-out row.
        XCTAssertFalse(AXPopupReader.isOnView(item("Helvetica", y: 900, order: 40), popup: popup))
        // AX withheld the frame entirely: still an item, still not a click target.
        XCTAssertFalse(AXPopupReader.isOnView(item("Zapfino", y: nil, order: 88), popup: popup))
    }

    // MARK: the scene it produces

    func testOnViewItemKeepsItsOwnRectAndOffViewItemFallsBackToTheMenuRect() {
        let menu = AXPopupReader.elements(
            from: [item("Arial", y: 210, order: 0), item("Helvetica", y: 4000, order: 42)],
            popup: popup, windowFrame: popup)
        XCTAssertEqual(menu.painted.count, 1)
        XCTAssertEqual(menu.offView.count, 1)
        // Normalized to the window frame the scene was perceived from (here the popup itself).
        XCTAssertEqual(menu.painted[0].pos[1], (210 - 200) / 120, accuracy: 0.0001)
        XCTAssertEqual(menu.painted[0].role, "AXMenuItem")
        XCTAssertEqual(menu.painted[0].kind, "control")
        XCTAssertEqual(menu.painted[0].does, "menu item")
        // The off-view row is IN the scene (that is the whole point) but never claims a landing spot
        // of its own: it carries the menu's rect and says so.
        XCTAssertEqual(menu.offView[0].label, "Helvetica")
        XCTAssertEqual(menu.offView[0].pos, [0, 0, 1, 1])   // the whole menu rect, normalized to itself
        XCTAssertTrue(menu.offView[0].does?.contains("off-view") == true, menu.offView[0].does ?? "nil")
    }

    /// The measured bug (TextEdit's font popup, live): an off-view row's rect is the WHOLE menu, so if it
    /// is handed to the position-based CV merge it contains — and overwrites — the painted row of the same
    /// name, taking its ✓ state with it. The split is the fix, so the split is the test.
    func testOffViewRowsAreKeptOutOfThePositionMerge() {
        let items = [item("Helvetica", y: 210, order: 1, checked: true),   // Recently Used, painted, ✓
                     item("Arial", y: 240, order: 2),
                     item("Helvetica", y: 3000, order: 45)]                // the alphabet's copy, off-view
        let menu = AXPopupReader.elements(from: items, popup: popup, windowFrame: popup)
        XCTAssertEqual(menu.painted.map(\.label), ["Helvetica", "Arial"])
        XCTAssertEqual(menu.offView.map(\.label), ["Helvetica #2"])
        // The painted row keeps its own ✓ state and its own rect — nothing overwrote it.
        XCTAssertEqual(menu.painted[0].state, "on")
        XCTAssertEqual(menu.painted[0].pos[1], (210 - 200) / 120, accuracy: 0.0001)
    }

    /// The other half of the same live failure: CV's OCR of a menu row and the AX row both claim the
    /// name, and `act(target:"Helvetica")` came back "2 elements labeled 'Helvetica'" — the row, and the
    /// row's own picture. Inside the menu AX is complete, so the CV copy goes; everything else stays.
    func testCVCopiesOfNamedRowsAreDroppedInsideTheMenuOnly() {
        let rows = AXPopupReader.elements(from: [item("Helvetica", y: 210, order: 1),
                                                item("Zapfino", y: 4000, order: 60)],
                                          popup: popup, windowFrame: popup).all
        let box: [Double] = [0, 0, 1, 1]   // the menu IS the window here
        let cv = [
            SceneElement(id: "a", kind: "text", label: "Helvetica", pos: [0.05, 0.05, 0.4, 0.02]),  // the row's OCR
            SceneElement(id: "b", kind: "text", label: "Recently Used", pos: [0.05, 0.01, 0.4, 0.02]), // AX didn't name it
            SceneElement(id: "c", kind: "icon", label: "(unlabeled)", pos: [0.9, 0.5, 0.05, 0.02], unlabeled: true),
        ]
        let kept = AXPopupReader.dropCVDuplicates(cv: cv, menuRows: rows, popupNormalized: box)
        XCTAssertEqual(kept.map(\.id), ["b", "c"])
        // A same-named element OUTSIDE the menu box is untouched — the window behind keeps its controls.
        let outside = [SceneElement(id: "d", kind: "control", label: "Helvetica", pos: [0.2, 0.6, 0.1, 0.02])]
        XCTAssertEqual(AXPopupReader.dropCVDuplicates(cv: outside, menuRows: rows,
                                                      popupNormalized: [0, 0, 1, 0.3]).map(\.id), ["d"])
    }

    func testCheckedItemCarriesStateAndSubmenuParentSaysSo() {
        let els = AXPopupReader.elements(
            from: [item("Show Ruler", y: 210, order: 0, checked: true),
                   item("Recent Documents", y: 240, order: 1, submenu: true),
                   item("Paste and Match Style", y: 270, order: 2, enabled: false)],
            popup: popup, windowFrame: popup).painted
        XCTAssertEqual(els[0].state, "on")
        XCTAssertNil(els[1].state)
        XCTAssertTrue(els[1].does?.contains("submenu") == true)
        XCTAssertTrue(els[2].does?.contains("disabled") == true)
    }

    func testDuplicateTitlesBecomeOrdinalSoResolveStaysUniqueAccept() {
        let els = AXPopupReader.elements(
            from: [item("Copy", y: 210, order: 0), item("Copy", y: 240, order: 1)],
            popup: popup, windowFrame: popup).painted
        XCTAssertEqual(els.map(\.label), ["Copy", "Copy #2"])
        XCTAssertNotEqual(els[0].id, els[1].id)   // distinct identities, not one ambiguous target
    }

    func testDegenerateWindowFrameProducesNothing() {
        XCTAssertTrue(AXPopupReader.elements(from: [item("Arial", y: 210, order: 0)],
                                             popup: popup, windowFrame: .zero).isEmpty)
    }

    // MARK: the match that guards a press

    func testMatchIsNumberPreservingAndOrdinalAware() {
        let items = [item("8 kHz", y: 210, order: 0), item("48 kHz", y: 240, order: 1),
                     item("Helvetica", y: 270, order: 2), item("Helvetica Neue", y: 300, order: 3)]
        XCTAssertEqual(AXPopupReader.match("48 kHz", in: items)?.title, "48 kHz")
        XCTAssertEqual(AXPopupReader.match("8 kHz", in: items)?.title, "8 kHz")
        XCTAssertEqual(AXPopupReader.match("Helvetica", in: items)?.title, "Helvetica")
        // The scene's ordinal suffix must still resolve to the item it disambiguated.
        XCTAssertEqual(AXPopupReader.match("Helvetica #2", in: items)?.title, "Helvetica")
        XCTAssertNil(AXPopupReader.match("Futura", in: items))
        XCTAssertNil(AXPopupReader.match("", in: items))
    }

    // MARK: the read-back that verifies a press

    func testReadsBackAcceptsTheControlsValueAndAWordBoundarySuffix() {
        XCTAssertTrue(AXPopupReader.readsBack("Helvetica", in: ["Untitled", "Helvetica", "12"]))
        XCTAssertTrue(AXPopupReader.readsBack("Helvetica", in: ["Font: Helvetica"]))
        XCTAssertFalse(AXPopupReader.readsBack("Helvetica", in: ["Helvetica Neue", "Arial"]))
        XCTAssertFalse(AXPopupReader.readsBack("Helvetica", in: []))
        XCTAssertFalse(AXPopupReader.readsBack("", in: ["Helvetica"]))
    }

    func testReadsBackNeverLetsANumberHideInsideABiggerOne() {
        // The PopupVision scar, re-guarded on the verification side: selecting "8 kHz" must not read
        // back as verified because the control says "48 kHz".
        XCTAssertFalse(AXPopupReader.readsBack("8 kHz", in: ["48 kHz"]))
        XCTAssertTrue(AXPopupReader.readsBack("48 kHz", in: ["48 kHz"]))
        XCTAssertTrue(AXPopupReader.readsBack("1080", in: ["HD 1080"]))   // real word boundary
    }

    // MARK: which AXMenu is the open one

    func testOverlapPicksTheMenuThatMatchesTheOpenPopupWindow() {
        let onScreen = CGRect(x: 402, y: 202, width: 216, height: 116)   // AX frame ≈ the popup window
        let elsewhere = CGRect(x: 0, y: 0, width: 200, height: 300)      // a menu-bar menu, not open
        XCTAssertGreaterThan(AXPopupReader.overlap(onScreen, popup), 0.9)
        XCTAssertEqual(AXPopupReader.overlap(elsewhere, popup), 0)
    }
}

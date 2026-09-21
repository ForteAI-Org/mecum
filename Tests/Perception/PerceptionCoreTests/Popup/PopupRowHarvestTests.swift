//
//  PopupRowHarvestTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import PerceptionCore
import Testing

/// Reading the open menu through the tree: which rows count, which are painted, and which of an
/// application's menus is the one on screen. No live accessibility and no screen.
@Suite("Popup rows through accessibility")
struct PopupRowHarvestTests {

    /// The pop-up window as the window server reports it.
    let popup = CGRect(x: 400, y: 200, width: 220, height: 120)

    private func item(_ title: String, y: CGFloat?, isEnabled: Bool = true) -> FakeNode {
        FakeNode("AXMenuItem", title: title,
                 frame: y.map { CGRect(x: 404, y: $0, width: 212, height: 20) },
                 isEnabled: isEnabled)
    }

    private func menu(_ frame: CGRect?, _ items: FakeNode...) -> FakeNode {
        let node = FakeNode("AXMenu", frame: frame)
        for item in items { node.adding(item) }
        return node
    }

    // MARK: rows a person could pick

    @Test("separators and titleless decoration are not rows")
    func selectableRows() {
        #expect(PopupRowHarvest.isSelectable("") == false)
        #expect(PopupRowHarvest.isSelectable("  ") == false)
        #expect(PopupRowHarvest.isSelectable("———") == false)      // a separator's glyph row
        #expect(PopupRowHarvest.isSelectable("Helvetica"))
        #expect(PopupRowHarvest.isSelectable("1920 x 1080 HD"))
        #expect(PopupRowHarvest.isSelectable(String(repeating: "x", count: 65)) == false)
    }

    @Test("a separator between two items neither names a row nor renumbers the ones after it")
    func separatorsKeepTheirPlaceInTheOrder() {
        let open = menu(popup, item("Arial", y: 210), item("", y: 230), item("Courier", y: 250))
        let rows = PopupRowHarvest.rows(of: open, popupFrame: popup, reader: FakeReader())
        #expect(rows.map(\.title) == ["Arial", "Courier"])
        #expect(rows.map(\.order) == [0, 2])
    }

    @Test("a row falls back to its description when it has no title")
    func descriptionNamesARow() {
        let described = FakeNode("AXMenuItem", descriptionText: "Zapfino",
                                 frame: CGRect(x: 404, y: 210, width: 212, height: 20))
        let rows = PopupRowHarvest.rows(of: menu(popup, described), popupFrame: popup, reader: FakeReader())
        #expect(rows.map(\.title) == ["Zapfino"])
    }

    @Test("a disabled row is read and said to be disabled, never dropped")
    func disabledRows() {
        let open = menu(popup, item("Paste and Match Style", y: 210, isEnabled: false))
        let rows = PopupRowHarvest.rows(of: open, popupFrame: popup, reader: FakeReader())
        #expect(rows.first?.isEnabled == false)
        #expect(rows.first?.isOnScreen == true)
    }

    @Test("nothing but a menu item becomes a row")
    func onlyMenuItemsBecomeRows() {
        let open = FakeNode("AXMenu", frame: popup).adding(
            item("Arial", y: 210),
            FakeNode("AXMenuItem", title: "Recently Used", frame: nil),
            FakeNode("AXStaticText", title: "Recently Used", frame: CGRect(x: 404, y: 205, width: 100, height: 12))
        )
        let rows = PopupRowHarvest.rows(of: open, popupFrame: popup, reader: FakeReader())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.title != "Recently Used" || $0.isOnScreen == false })
    }

    // MARK: painted or scrolled out

    @Test("a row is on screen only with a frame inside the open pop-up")
    func onScreenNeedsAFrameInsideThePopup() {
        #expect(PopupRowHarvest.isOnScreen(CGRect(x: 404, y: 260, width: 212, height: 20), in: popup))
        // Below the painted box: a long menu's scrolled-out row.
        #expect(PopupRowHarvest.isOnScreen(CGRect(x: 404, y: 900, width: 212, height: 20), in: popup) == false)
        // Accessibility withheld the frame: still a row, still not a click target.
        #expect(PopupRowHarvest.isOnScreen(nil, in: popup) == false)
        // A degenerate frame is no frame.
        #expect(PopupRowHarvest.isOnScreen(CGRect(x: 404, y: 210, width: 0, height: 0), in: popup) == false)
    }

    /// The measured TextEdit case: 20 families painted, "Helvetica" two pages below, and an act on
    /// it honestly missed because the scene never held it.
    @Test("a scrolled-out row is still a row, marked off screen and carrying no rect")
    func scrolledOutRowsSurvive() {
        let open = menu(popup, item("Arial", y: 210), item("Helvetica", y: 4000), item("Zapfino", y: nil))
        let rows = PopupRowHarvest.rows(of: open, popupFrame: popup, reader: FakeReader())
        #expect(rows.map(\.title) == ["Arial", "Helvetica", "Zapfino"])
        #expect(rows.map(\.isOnScreen) == [true, false, false])
        #expect(rows[0].frame == CGRect(x: 404, y: 210, width: 212, height: 20))
        #expect(rows[2].frame == nil)
    }

    @Test("a long list is capped rather than allowed to flood a scene")
    func rowsAreCapped() {
        let open = FakeNode("AXMenu", frame: popup)
        for index in 0..<40 { open.adding(item("Row \(index)", y: 210)) }
        let rows = PopupRowHarvest.rows(of: open, popupFrame: popup, reader: FakeReader(),
                                        limits: PopupRowHarvest.Limits(maxRows: 12))
        #expect(rows.count == 12)
    }

    @Test("a budget that is already spent reads nothing rather than hanging on a tracking menu")
    func deadlineStopsTheRead() {
        let open = menu(popup, item("Arial", y: 210))
        let rows = PopupRowHarvest.rows(of: open, popupFrame: popup, reader: FakeReader(),
                                        limits: PopupRowHarvest.Limits(isPastDeadline: { true }))
        #expect(rows.isEmpty)
    }

    // MARK: which menu is the open one

    @Test("overlap picks the menu whose frame is the open pop-up window")
    func overlapRanksByWhatIsOnScreen() {
        let onScreen = CGRect(x: 402, y: 202, width: 216, height: 116)   // the frame IS the pop-up
        let elsewhere = CGRect(x: 0, y: 0, width: 200, height: 300)      // a menu-bar menu, not open
        #expect(PopupRowHarvest.overlap(onScreen, popup) > 0.9)
        #expect(PopupRowHarvest.overlap(elsewhere, popup) == 0)
    }

    /// The measured menu-bar shape: eight closed menus reporting a zero-size frame, and the one that
    /// is pulled down. Reading the frame before the children is what keeps the budget.
    @Test("the menu that matches the pop-up wins over every closed menu in the bar")
    func theOpenMenuIsFoundAmongClosedOnes() {
        let bar = FakeNode("AXMenuBar", frame: CGRect(x: 0, y: 0, width: 1512, height: 24))
        for title in ["File", "Edit", "Format", "View"] {
            bar.adding(FakeNode("AXMenuBarItem", title: title, frame: CGRect(x: 0, y: 0, width: 40, height: 24))
                .adding(menu(CGRect(x: 0, y: 982, width: 0, height: 0), item("\(title) item", y: 210))))
        }
        let open = menu(CGRect(x: 402, y: 202, width: 216, height: 116),
                        item("Arial", y: 210), item("Helvetica", y: 4000))
        let application = FakeNode("AXApplication").adding(bar, open)
        let rows = PopupRowHarvest.rows(among: [application], popupFrame: popup, reader: FakeReader())
        #expect(rows.map(\.title) == ["Arial", "Helvetica"])
    }

    @Test("an empty menu is not the one on screen")
    func emptyMenusAreNotCandidates() {
        let application = FakeNode("AXApplication").adding(menu(CGRect(x: 402, y: 202, width: 216, height: 116)))
        #expect(PopupRowHarvest.rows(among: [application], popupFrame: popup, reader: FakeReader()).isEmpty)
    }

    /// The toolkit that paints its own list: no menu exists for the pop-up at all, and handing back
    /// some other populated menu would name rows that are not on screen AND tell the caller
    /// accessibility answered, skipping the row cut that can read those pixels.
    @Test("a framed pop-up no menu matches yields nothing, never another menu's rows")
    func aFramedPopupNeverFallsBackToAnotherMenu() {
        let parked = menu(nil, item("Arial", y: 210), item("Courier", y: 240))
        let application = FakeNode("AXApplication").adding(parked)
        #expect(PopupRowHarvest.rows(among: [application], popupFrame: popup, reader: FakeReader()).isEmpty)
    }

    @Test("with no pop-up frame a single populated menu is unambiguous and several are not")
    func framelessFallbackTakesOneOrNone() {
        let single = FakeNode("AXApplication").adding(menu(nil, item("Arial", y: 210)))
        #expect(PopupRowHarvest.rows(among: [single], popupFrame: nil, reader: FakeReader()).map(\.title) == ["Arial"])

        let several = FakeNode("AXApplication").adding(menu(nil, item("Arial", y: 210)),
                                                       menu(nil, item("Courier", y: 240)))
        #expect(PopupRowHarvest.rows(among: [several], popupFrame: nil, reader: FakeReader()).isEmpty)
    }

    @Test("the roots are searched in order, so the focused window answers before the bar")
    func rootsAreSearchedInOrder() {
        let window = FakeNode("AXWindow").adding(
            FakeNode("AXPopUpButton", frame: CGRect(x: 400, y: 180, width: 220, height: 20))
                .adding(menu(CGRect(x: 402, y: 202, width: 216, height: 116), item("Arial", y: 210)))
        )
        let application = FakeNode("AXApplication").adding(
            menu(CGRect(x: 402, y: 202, width: 216, height: 116), item("Wrong", y: 210))
        )
        let rows = PopupRowHarvest.rows(among: [window, application], popupFrame: popup, reader: FakeReader())
        #expect(rows.map(\.title) == ["Arial"])
    }

    // MARK: the shape both eyes share

    @Test("pixel rows become pop-up rows without changing vocabulary")
    func pixelRowsBridge() {
        let cut = [PopupRowSegmenter.Row(text: "Arial", rect: CGRect(x: 0, y: 0, width: 200, height: 20),
                                         textRect: CGRect(x: 4, y: 2, width: 60, height: 16)),
                   PopupRowSegmenter.Row(text: "Courier", rect: CGRect(x: 0, y: 20, width: 200, height: 20),
                                         textRect: CGRect(x: 4, y: 22, width: 70, height: 16))]
        let rows = PopupRow.rows(cut)
        #expect(rows.map(\.title) == ["Arial", "Courier"])
        #expect(rows.map(\.order) == [0, 1])
        #expect(rows.allSatisfy { $0.isOnScreen }, "a row read off the screen is painted by construction")
        #expect(rows[1].frame == CGRect(x: 0, y: 20, width: 200, height: 20))
    }
}

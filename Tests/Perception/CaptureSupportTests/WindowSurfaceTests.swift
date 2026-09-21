import XCTest
import CoreGraphics
@testable import CaptureSupport

/// THE TICKET-12 BUG, pinned: two functions in one file disagreeing about what a pop-up is.
///
/// `frontmostWindowFrame` picked DaVinci's open resolution list (it is the frontmost substantial
/// window, so its plain-window branch took it) while `openPopupFrames` returned NOTHING for the same
/// frame (its only branch is the 21…200 menu-layer range). The scene was therefore built on the
/// pop-up's pixels but never entered the pop-up paths — no AX item read (ticket 06), no row cut
/// (ticket 07) — and `describe_section` showed 32 unlabeled fragments plus one run-on blob.
///
/// Both are now answers from ONE classifier over ONE enumeration, so the disagreement is structurally
/// impossible; `testThePickerAndTheDetectorCanNeverDisagree` is the assertion that says so.
final class WindowSurfaceTests: XCTestCase {

    // MARK: - shapes measured on the machine

    private func row(_ layer: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     _ title: String? = nil, number: Int = 0) -> WindowRow {
        WindowRow(layer: layer, frameGlobalPt: CGRect(x: x, y: y, width: w, height: h),
                  title: title, number: number)
    }

    /// DaVinci Resolve 20, Project Settings → Timeline resolution, list OPEN. The dialog is 1040×736pt
    /// (measured from the `davinci-project-settings.png` fixture at 2× = 2080×1472px); the list hangs
    /// off the combo in the middle of it, over the "For 3840 x 2160 processing" fields, the "Use
    /// vertical resolution" checkbox and the pixel-aspect radios — which is exactly why AX reported
    /// those five controls INSIDE what the scene called the pop-up section.
    ///
    /// The list's own size is DERIVED from the report rather than measured: the old picker chose it,
    /// and the only way it could was `isSubstantialWindow` (≥200×90pt, ≥40k pt²) — so the list is at
    /// least 200pt wide, wider than the 190pt combo it hangs off (Qt sizes a dropdown to its longest
    /// item, here "720 x 576 PAL 16:9"). 260×420 is that shape. Its exact frame is the one number in
    /// this file still owed a live measurement (`debug-popup --watch`).
    private var davinciWithListOpen: [WindowRow] {
        [row(0, 676, 283, 260, 420),                                 // the open list — untitled
         row(0, 236, 123, 1040, 736, "Project Settings: Untitled Project 1"),
         row(0, 0, 194, 1360, 714, "tracks")]                        // the main window
    }

    // MARK: - the bug

    func testDaVincisWindowLayerDropdownIsSeenAsAPopup() {
        let s = WindowSurfaceClassifier.classify(davinciWithListOpen)
        XCTAssertEqual(s.popups, [CGRect(x: 676, y: 283, width: 260, height: 420)],
                       "the open list is the pop-up — this is the frame ticket 06/07's paths need")
        XCTAssertEqual(s.interaction?.frameGlobalPt, s.popups.first,
                       "and the window we drive is that same list")
        XCTAssertEqual(s.verdicts.first?.kind, .floatingList)
    }

    func testThePickerAndTheDetectorCanNeverDisagree() {
        // The property the ticket is about, over every fixture in this file: if a pop-up is detected,
        // it IS the interaction surface. One classifier, one enumeration, one answer.
        for (name, rows) in allFixtures {
            let s = WindowSurfaceClassifier.classify(rows)
            if let popup = s.popups.first {
                XCTAssertEqual(s.interaction?.frameGlobalPt, popup, "\(name): detector says popup, picker disagreed")
            }
        }
    }

    // MARK: - what must NOT become a pop-up

    func testProToolsNewTracksDialogStaysAWindow() {
        // 815×124 on layer 8 over the edit window: a SHORT WIDE MODAL. It is contained in a much
        // bigger sibling like a dropdown is, so shape is what separates them — a list is never 6.6×
        // wider than tall.
        let rows = [row(8, 350, 400, 815, 124, "New Tracks"), row(0, 0, 100, 1500, 900, "Edit: Session")]
        let s = WindowSurfaceClassifier.classify(rows)
        XCTAssertTrue(s.popups.isEmpty)
        XCTAssertEqual(s.interaction?.frameGlobalPt, rows[0].frameGlobalPt, "the modal is still what we drive")
    }

    func testAnUntitledShortWideDialogIsStillNotAPopup() {
        // The same shape with no title — two independent guards, so losing one does not lose the case.
        let rows = [row(8, 350, 400, 815, 124), row(0, 0, 100, 1500, 900, "Edit: Session")]
        XCTAssertTrue(WindowSurfaceClassifier.classify(rows).popups.isEmpty)
    }

    func testADockedPaletteIsNotAPopup() {
        // Untitled, narrow, tall, over the main window — a dropdown by every clause except the one
        // that matters: it HUGS three of its parent's edges. A list hangs in the middle of the window.
        let rows = [row(3, 0, 194, 120, 714), row(0, 0, 194, 1360, 714, "tracks")]
        let s = WindowSurfaceClassifier.classify(rows)
        XCTAssertTrue(s.popups.isEmpty)
        XCTAssertEqual(s.verdicts.first?.kind, .window)
    }

    func testATitledDialogIsNotAPopupEvenInListShape() {
        let rows = [row(0, 700, 300, 190, 400, "Rename"), row(0, 0, 194, 1360, 714, "tracks")]
        XCTAssertTrue(WindowSurfaceClassifier.classify(rows).popups.isEmpty)
    }

    func testAWindowWithNoBiggerSiblingBehindItIsNotAPopup() {
        // A narrow untitled tool window on its own. Nothing to be a dropdown OF.
        let rows = [row(0, 700, 300, 190, 400)]
        XCTAssertTrue(WindowSurfaceClassifier.classify(rows).popups.isEmpty)
    }

    func testASiblingThatIsBarelyBiggerIsNotAParent() {
        // DaVinci's Project Settings dialog (1040×736) over its main window (1360×714) is 1.3× —
        // nothing like the 12× a dropdown-to-parent ratio is. A dialog must not read as a list of
        // the window it covers, so the ratio gate is what rejects it (and its 1.41 aspect too).
        let rows = [row(0, 236, 123, 1040, 736), row(0, 0, 194, 1360, 714, "tracks")]
        XCTAssertTrue(WindowSurfaceClassifier.classify(rows).popups.isEmpty)
    }

    func testAWindowLayerListBehindARealWindowIsNotTheInteractionSurface() {
        // Only the FRONTMOST surface can be an open pop-up. Behind a real window it is just a window.
        let rows = [row(0, 0, 100, 1200, 800, "Document"),
                    row(0, 676, 283, 190, 400),
                    row(0, 0, 194, 1360, 714, "tracks")]
        let s = WindowSurfaceClassifier.classify(rows)
        XCTAssertTrue(s.popups.isEmpty)
        XCTAssertEqual(s.interaction?.frameGlobalPt, rows[0].frameGlobalPt)
    }

    func testUnreadableTitlesDisableTheWindowLayerRule() {
        // Without Screen Recording every window is untitled, and "untitled" would stop meaning
        // anything — a modal dialog would read as a dropdown. When no window of the app has a
        // readable title, the rule declines to fire and behaviour is exactly as it was.
        let rows = [row(0, 676, 283, 260, 420), row(0, 236, 123, 1040, 736), row(0, 0, 194, 1360, 714)]
        let s = WindowSurfaceClassifier.classify(rows)
        XCTAssertTrue(s.popups.isEmpty, "no titles anywhere → no evidence to lean on")
        XCTAssertEqual(s.interaction?.frameGlobalPt, rows[0].frameGlobalPt,
                       "unchanged: the front substantial window still wins the choice")
    }

    /// With the rule off, this fixture reproduces TICKET 12 ITSELF: the picker drives the list (it is
    /// the frontmost substantial window) while the detector reports no pop-up at all. That is the
    /// disagreement, and it is what `LOCATOR_NO_WINDOW_LAYER_POPUPS` restores if the new rule ever
    /// needs to be switched off live.
    func testTheRuleCanBeTurnedOffAndThatRestoresTheBug() {
        let s = WindowSurfaceClassifier.classify(davinciWithListOpen, allowFloatingLists: false)
        XCTAssertTrue(s.popups.isEmpty, "the detector's old answer: no pop-up open")
        XCTAssertEqual(s.interaction?.frameGlobalPt, davinciWithListOpen[0].frameGlobalPt,
                       "the picker's old answer: drive the list anyway")
    }

    // MARK: - menu-layer pop-ups keep working exactly as they did

    func testPremieresMenuLayerFormatListIsUnchanged() {
        // Measured in ticket 07: popup[0] (471,298 296×432) on a menu layer, main window 1058×874.
        let rows = [row(101, 471, 298, 296, 432), row(0, 35, 34, 1058, 874, "/Users/…/project.prproj")]
        let s = WindowSurfaceClassifier.classify(rows)
        XCTAssertEqual(s.popups, [rows[0].frameGlobalPt])
        XCTAssertEqual(s.verdicts.first?.kind, .popupLayer)
    }

    func testProToolsTinyDropdownOnAMenuLayerCounts() {
        // 129×197 on layer 101 — under the "substantial window" bar, and the whole reason the pop-up
        // branch exists.
        let rows = [row(101, 900, 300, 129, 197), row(0, 0, 100, 1500, 900, "Edit: Session")]
        XCTAssertEqual(WindowSurfaceClassifier.classify(rows).popups, [rows[0].frameGlobalPt])
    }

    func testASubmenuKeepsBothPopupsFrontToBack() {
        let rows = [row(101, 1000, 400, 200, 300), row(101, 900, 300, 129, 197),
                    row(0, 0, 100, 1500, 900, "Edit: Session")]
        let s = WindowSurfaceClassifier.classify(rows)
        XCTAssertEqual(s.popups.count, 2)
        XCTAssertEqual(s.popups.first, rows[0].frameGlobalPt, "front-to-back: the submenu leads")
    }

    func testAMenuLayerSliverIsChromeNotAPopup() {
        let rows = [row(101, 900, 300, 40, 20), row(0, 0, 100, 1500, 900, "Edit: Session")]
        let s = WindowSurfaceClassifier.classify(rows)
        XCTAssertTrue(s.popups.isEmpty)
        XCTAssertEqual(s.interaction?.frameGlobalPt, rows[1].frameGlobalPt)
    }

    // MARK: - the picker's own behaviour, unchanged

    func testAShortWideModalStillBeatsTheWindowBehindIt() {
        let rows = [row(8, 350, 400, 815, 124, "New Tracks"), row(0, 0, 100, 1500, 900, "Edit: Session")]
        XCTAssertEqual(WindowSurfaceClassifier.classify(rows).interaction?.frameGlobalPt, rows[0].frameGlobalPt)
    }

    func testATooltipInFrontIsSkippedForTheWindow() {
        let rows = [row(0, 400, 400, 300, 40, "tip"), row(0, 0, 100, 1500, 900, "Edit: Session")]
        XCTAssertEqual(WindowSurfaceClassifier.classify(rows).interaction?.frameGlobalPt, rows[1].frameGlobalPt)
    }

    func testTheLargestLayerZeroWindowIsTheLastResort() {
        // Nothing substantial: a floating strip on layer 3 must not win the fallback just by being big.
        let rows = [row(3, 0, 0, 1400, 60, "strip"), row(0, 100, 100, 300, 80, "small doc")]
        XCTAssertEqual(WindowSurfaceClassifier.classify(rows).interaction?.frameGlobalPt, rows[1].frameGlobalPt)
    }

    func testNoWindowsAtAll() {
        XCTAssertNil(WindowSurfaceClassifier.classify([]).interaction)
        XCTAssertTrue(WindowSurfaceClassifier.classify([]).popups.isEmpty)
    }

    // MARK: - the rejection has to say WHY (a miss carries the next move — ticket 09)

    func testARejectionNamesTheClauseThatFailed() {
        let rows = [row(8, 350, 400, 815, 124, "New Tracks"), row(0, 0, 100, 1500, 900, "Edit: Session")]
        let s = WindowSurfaceClassifier.classify(rows)
        let why = s.verdicts[0].why
        XCTAssertTrue(why.contains("titled"), "expected the clause and its numbers, got: \(why)")
        // And the shape clause is reachable too, with the measured aspect in it.
        let untitled = WindowSurfaceClassifier.floatingList(row(8, 350, 400, 815, 124),
                                                            behind: [rows[1]], titlesLegible: true)
        guard case .no(let clause) = untitled else { return XCTFail("expected a rejection") }
        XCTAssertTrue(clause.contains("6.5") || clause.contains("6.6"), "expected the w/h number, got: \(clause)")
    }

    func testTheAcceptanceSaysWhichParentItHangsOver() {
        let s = WindowSurfaceClassifier.classify(davinciWithListOpen)
        XCTAssertTrue(s.verdicts[0].why.contains("1040"), "expected the parent's size, got: \(s.verdicts[0].why)")
    }

    // MARK: -

    private var allFixtures: [(String, [WindowRow])] {
        [("davinci", davinciWithListOpen),
         ("premiere-menu-layer", [row(101, 471, 298, 296, 432), row(0, 35, 34, 1058, 874, "p.prproj")]),
         ("protools-new-tracks", [row(8, 350, 400, 815, 124, "New Tracks"), row(0, 0, 100, 1500, 900, "Edit")]),
         ("submenu", [row(101, 1000, 400, 200, 300), row(101, 900, 300, 129, 197),
                      row(0, 0, 100, 1500, 900, "Edit")]),
         ("palette", [row(3, 0, 194, 120, 714), row(0, 0, 194, 1360, 714, "tracks")]),
         ("empty", [])]
    }
}

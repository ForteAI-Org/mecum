import XCTest
import CoreGraphics
@testable import CaptureSupport

/// Which windows count as "the one the user is looking at". This gate decides whether a modal dialog
/// gets perceived at all, so the real shapes that burned us are pinned here.
final class SubstantialWindowTests: XCTestCase {
    private func sub(_ w: CGFloat, _ h: CGFloat) -> Bool {
        WindowCaptureService.isSubstantialWindow(CGRect(x: 0, y: 0, width: w, height: h))
    }

    func testShortWideDialogsCount() {
        // Pro Tools "New Tracks" — 815×124. The old `height >= 140` rule skipped it, so the engine
        // captured the edit window behind the modal it was supposed to drive.
        XCTAssertTrue(sub(815, 124))
        XCTAssertTrue(sub(600, 100), "a confirm sheet is short and wide")
        XCTAssertTrue(sub(420, 96))
    }

    func testNormalWindowsCount() {
        XCTAssertTrue(sub(947, 873))    // Pro Tools edit window
        XCTAssertTrue(sub(1512, 982))   // full-screen app
        XCTAssertTrue(sub(500, 500))    // plugin window
    }

    func testTooltipsAndBadgesDoNot() {
        XCTAssertFalse(sub(300, 40), "a tooltip is thin")
        XCTAssertFalse(sub(120, 120), "a badge/HUD is small in both dimensions")
        XCTAssertFalse(sub(1512, 33), "a menu-bar strip is not a window to drive")
        XCTAssertFalse(sub(180, 400), "too narrow to be a dialog")
        XCTAssertFalse(sub(220, 150), "big enough on each side but too little area (33k)")
    }
}

/// Which CGWindow LAYERS we're willing to drive. Pro apps park modals and palettes on floating
/// layers, and a `layer == 0` filter makes them invisible — measured on Pro Tools, where "New Tracks"
/// sat on layer 0 while focused and moved to LAYER 8 in the moment right after a menu click.
final class WindowLayerTests: XCTestCase {
    func testNormalAndFloatingLayersAreDrivable() {
        XCTAssertTrue(WindowCaptureService.isWindowLayer(0), "normal windows")
        XCTAssertTrue(WindowCaptureService.isWindowLayer(3), "floating/utility panels")
        XCTAssertTrue(WindowCaptureService.isWindowLayer(8), "Pro Tools' New Tracks, transiently")
        XCTAssertTrue(WindowCaptureService.isWindowLayer(20))
    }

    func testChromeLayersAreNot() {
        XCTAssertFalse(WindowCaptureService.isWindowLayer(25), "status items")
        XCTAssertFalse(WindowCaptureService.isWindowLayer(101), "pop-up menus")
        XCTAssertFalse(WindowCaptureService.isWindowLayer(500), "cursor / screensaver")
        XCTAssertFalse(WindowCaptureService.isWindowLayer(-1), "below the desktop")
    }
}

/// OPEN POP-UP MENUS. A dropdown's list is a small window on a menu layer — discarded by both the
/// layer gate and the size gate — yet while it is open it is the ONLY thing the user can interact
/// with. Measured on Pro Tools: the track-type dropdown is 129×197 on layer 101, holding "Routing
/// Folder"; the agent clicked the dropdown, read nothing, and never found the option.
final class PopupLayerTests: XCTestCase {
    func testMenuLayersCountAsPopups() {
        XCTAssertTrue(WindowCaptureService.isPopupLayer(101), "Pro Tools' track-type dropdown")
        XCTAssertTrue(WindowCaptureService.isPopupLayer(25))
        XCTAssertTrue(WindowCaptureService.isPopupLayer(200))
    }

    func testOrdinaryAndExtremeLayersAreNotPopups() {
        XCTAssertFalse(WindowCaptureService.isPopupLayer(0), "a normal window is not a popup")
        XCTAssertFalse(WindowCaptureService.isPopupLayer(8), "a floating dialog is a window, not a popup")
        XCTAssertFalse(WindowCaptureService.isPopupLayer(500), "cursor / screensaver")
    }

    func testPopupAndWindowLayersDoNotOverlap() {
        for l in -1...600 {
            XCTAssertFalse(WindowCaptureService.isWindowLayer(l) && WindowCaptureService.isPopupLayer(l),
                           "layer \(l) classified as both")
        }
    }
}

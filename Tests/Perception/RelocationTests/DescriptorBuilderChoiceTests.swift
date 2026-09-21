import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

/// The reliability-critical element-box choice (the fix for coarse 1500×1048 captures).
final class DescriptorBuilderChoiceTests: XCTestCase {
    let window = CGRect(x: 0, y: 0, width: 1000, height: 800)   // area 800k; coarse if area>120k or side>500
    let click = CGPoint(x: 500, y: 400)
    let tuning = RelocationTuning.defaults

    func testPreciseCVWinsOverCoarseAX() {
        let r = DescriptorBuilder.chooseElementBox(
            clickPx: click, axElementPx: CGRect(x: 0, y: 0, width: 800, height: 600),
            cvBox: CGRect(x: 480, y: 390, width: 60, height: 40), opaque: false, imageRect: window, tuning: tuning)
        XCTAssertEqual(r.box, CGRect(x: 480, y: 390, width: 60, height: 40))
        XCTAssertFalse(r.keepAX)
    }

    func testNoPreciseBoxFallsBackToClickCenteredBox() {   // the steps-1/2 failure
        let r = DescriptorBuilder.chooseElementBox(
            clickPx: click, axElementPx: CGRect(x: 0, y: 0, width: 900, height: 700),
            cvBox: nil, opaque: false, imageRect: window, tuning: tuning)
        XCTAssertEqual(r.box, CGRect(x: 468, y: 368, width: 64, height: 64))   // 64px centered on the click
        XCTAssertFalse(r.keepAX)
    }

    func testPreciseAXKeptWhenNoCV() {
        let r = DescriptorBuilder.chooseElementBox(
            clickPx: click, axElementPx: CGRect(x: 100, y: 100, width: 120, height: 30),
            cvBox: nil, opaque: false, imageRect: window, tuning: tuning)
        XCTAssertEqual(r.box, CGRect(x: 100, y: 100, width: 120, height: 30))
        XCTAssertTrue(r.keepAX)
    }

    func testTighterCVPreferredOverComparableAX() {
        // cv 30×20=600 < 0.5 · ax(200×100=20000) → CV is much tighter → use it
        let r = DescriptorBuilder.chooseElementBox(
            clickPx: click, axElementPx: CGRect(x: 0, y: 0, width: 200, height: 100),
            cvBox: CGRect(x: 490, y: 395, width: 30, height: 20), opaque: false, imageRect: window, tuning: tuning)
        XCTAssertEqual(r.box.width, 30)
        XCTAssertFalse(r.keepAX)
    }

    func testComparableCVKeepsAXPath() {
        // cv 150×100=15000 ≥ 0.5 · ax(160×110=17600) → keep AX (preserve its replay path)
        let r = DescriptorBuilder.chooseElementBox(
            clickPx: click, axElementPx: CGRect(x: 0, y: 0, width: 160, height: 110),
            cvBox: CGRect(x: 0, y: 0, width: 150, height: 100), opaque: false, imageRect: window, tuning: tuning)
        XCTAssertEqual(r.box.width, 160)
        XCTAssertTrue(r.keepAX)
    }

    func testOpaqueIgnoresAXAndFallsBackWhenNoCV() {
        let r = DescriptorBuilder.chooseElementBox(
            clickPx: click, axElementPx: CGRect(x: 0, y: 0, width: 100, height: 30),
            cvBox: nil, opaque: true, imageRect: window, tuning: tuning)
        XCTAssertEqual(r.box.width, 64)   // opaque → AX ignored → click-centered fallback
        XCTAssertFalse(r.keepAX)
    }

    // MARK: textAlignedBox — snap a CV fragment up to its full text run

    func testTextAlignedBoxSnapsFragmentToFullRun() {
        // CV grabbed "2048" (a piece); the click/center sits inside the full "3072 x 2048 VistaVision" run.
        let fragment = CGRect(x: 480, y: 220, width: 40, height: 24)
        let runs: [(text: String, box: CGRect)] = [
            ("3072 x 2048 VistaVision", CGRect(x: 400, y: 218, width: 220, height: 26)),
            ("Use vertical resolution", CGRect(x: 400, y: 300, width: 180, height: 20)),
        ]
        let r = DescriptorBuilder.textAlignedBox(fragment: fragment, keepAX: false, ocrRuns: runs, imageRect: window, tuning: tuning)
        XCTAssertEqual(r, CGRect(x: 400, y: 218, width: 220, height: 26).integral)
    }

    func testTextAlignedBoxNoOpWhenAXKept() {
        let fragment = CGRect(x: 480, y: 220, width: 40, height: 24)
        let runs: [(text: String, box: CGRect)] = [("Label", CGRect(x: 400, y: 218, width: 220, height: 26))]
        let r = DescriptorBuilder.textAlignedBox(fragment: fragment, keepAX: true, ocrRuns: runs, imageRect: window, tuning: tuning)
        XCTAssertEqual(r, fragment)   // precise AX leaf kept → never snap
    }

    func testTextAlignedBoxNoOpWhenNoRunContainsCenter() {
        let fragment = CGRect(x: 480, y: 220, width: 40, height: 24)   // center (500,232)
        let runs: [(text: String, box: CGRect)] = [("elsewhere", CGRect(x: 0, y: 0, width: 80, height: 20))]
        let r = DescriptorBuilder.textAlignedBox(fragment: fragment, keepAX: false, ocrRuns: runs, imageRect: window, tuning: tuning)
        XCTAssertEqual(r, fragment)   // no text under the fragment (e.g. an icon) → keep the fragment
    }
}

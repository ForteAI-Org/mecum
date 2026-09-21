import XCTest
import CoreGraphics
@testable import Relocation

/// The sample-rate bug, pinned: a live agent asked for "44.1 kHz" and PopupVision picked "8 kHz"
/// forever, because LocatorMemory.core() stripped the leading numbers and collapsed EVERY rate to
/// "khz". PopupVision must match on numbers.
final class PopupVisionMatchTests: XCTestCase {
    func item(_ t: String) -> PopupVision.Item { .init(text: t, rectGlobalPt: .zero) }
    let rates = ["8 kHz", "11.025 kHz", "44.1 kHz", "48 kHz", "88.2 kHz", "96 kHz"].map { PopupVision.Item(text: $0, rectGlobalPt: .zero) }

    func testSampleRateExact() {
        XCTAssertEqual(PopupVision.match("44.1 kHz", in: rates)?.text, "44.1 kHz")
        XCTAssertEqual(PopupVision.match("48 kHz", in: rates)?.text, "48 kHz")
        XCTAssertEqual(PopupVision.match("8 kHz", in: rates)?.text, "8 kHz")
        XCTAssertEqual(PopupVision.match("96 kHz", in: rates)?.text, "96 kHz")
    }

    func testNumbersAreNotCollapsed() {
        // "48" must never resolve to "8" and vice-versa.
        XCTAssertEqual(PopupVision.match("48 kHz", in: rates)?.text, "48 kHz")
        XCTAssertNotEqual(PopupVision.match("48 kHz", in: rates)?.text, "8 kHz")
    }

    func testCaseAndJitter() {
        XCTAssertEqual(PopupVision.match("44.1 KHZ", in: rates)?.text, "44.1 kHz")   // OCR all-caps
        let withExtra = [item("44.1 kHz (Recommended)"), item("48 kHz")]
        XCTAssertEqual(PopupVision.match("44.1 kHz", in: withExtra)?.text, "44.1 kHz (Recommended)")
    }

    func testNamesStillMatch() {
        let folders = [item("customer routing for Ron 1"), item("customer routing for Ron 2")]
        XCTAssertEqual(PopupVision.match("customer routing for Ron 2", in: folders)?.text, "customer routing for Ron 2")
        XCTAssertEqual(PopupVision.match("Routing Folder", in: [item("Routing Folder"), item("Basic Folder")])?.text, "Routing Folder")
    }

    func testNoFalseMatch() {
        XCTAssertNil(PopupVision.match("192 kHz", in: rates))   // not present → honest nil, not "8 kHz"
    }
}

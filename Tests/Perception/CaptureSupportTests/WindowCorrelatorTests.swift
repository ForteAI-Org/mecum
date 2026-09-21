import XCTest
import CoreGraphics
@testable import CaptureSupport

private struct FakeWindow: CorrelatableWindow {
    var bundleID: String?
    var title: String?
    var frameGlobalPt: CGRect
    var isOnScreen: Bool = true
    var windowLayer: Int = 0
}

final class WindowCorrelatorTests: XCTestCase {
    let bid = "com.apple.TextEdit"
    let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testPicksFrameMatchingSameBundleWindow() {
        let target = FakeWindow(bundleID: bid, title: "Untitled", frameGlobalPt: frame)
        let other = FakeWindow(bundleID: bid, title: "Other", frameGlobalPt: CGRect(x: 2000, y: 0, width: 400, height: 300))
        let result = WindowCorrelator.correlate(axWindowFrameGlobalPt: frame, bundleID: bid, title: "Untitled", among: [other, target])
        XCTAssertEqual(result?.title, "Untitled")
    }

    func testExcludesOtherBundles() {
        let wrongBundle = FakeWindow(bundleID: "com.other.app", title: "X", frameGlobalPt: frame)
        let result = WindowCorrelator.correlate(axWindowFrameGlobalPt: frame, bundleID: bid, title: "X", among: [wrongBundle])
        XCTAssertNil(result)
    }

    func testTitleBreaksTieBetweenIdenticalFrames() {
        let a = FakeWindow(bundleID: bid, title: "Edit: Song A", frameGlobalPt: frame)
        let b = FakeWindow(bundleID: bid, title: "Edit: Song B", frameGlobalPt: frame)
        let result = WindowCorrelator.correlate(axWindowFrameGlobalPt: frame, bundleID: bid, title: "Edit: Song B", among: [a, b])
        XCTAssertEqual(result?.title, "Edit: Song B")
    }

    func testRejectsWhenNoPlausibleOverlap() {
        let far = FakeWindow(bundleID: bid, title: "X", frameGlobalPt: CGRect(x: 5000, y: 5000, width: 100, height: 100))
        let result = WindowCorrelator.correlate(axWindowFrameGlobalPt: frame, bundleID: bid, title: nil, among: [far])
        XCTAssertNil(result)
    }

    func testFrontmostBreaksTieWhenNoTitle() {
        let back = FakeWindow(bundleID: bid, title: nil, frameGlobalPt: frame, isOnScreen: true, windowLayer: 5)
        let front = FakeWindow(bundleID: bid, title: nil, frameGlobalPt: frame, isOnScreen: true, windowLayer: 0)
        let result = WindowCorrelator.correlate(axWindowFrameGlobalPt: frame, bundleID: bid, title: nil, among: [back, front])
        XCTAssertEqual(result?.windowLayer, 0)
    }

    func testIoU() {
        let r = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(WindowCorrelator.iou(r, r), 1.0, accuracy: 1e-9)
        XCTAssertEqual(WindowCorrelator.iou(r, CGRect(x: 20, y: 20, width: 10, height: 10)), 0)
        // 50% overlap on x → intersection 50, union 150 → 1/3
        XCTAssertEqual(WindowCorrelator.iou(r, CGRect(x: 5, y: 0, width: 10, height: 10)), 1.0 / 3.0, accuracy: 1e-9)
    }
}

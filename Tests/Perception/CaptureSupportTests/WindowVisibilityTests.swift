import XCTest
import CoreGraphics
@testable import CaptureSupport

final class WindowVisibilityTests: XCTestCase {
    func testOccludedCenterLeavesDisjointVisiblePieces() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 100)
        let cover = CGRect(x: 30, y: 40, width: 40, height: 40)
        let pieces = WindowVisibility.pieces(of: frame, excluding: [cover])
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.width * $1.height }, 8400)
        for (i, r) in pieces.enumerated() {
            XCTAssertTrue(r.intersection(cover).isEmpty || r.intersection(cover).isNull)
            for other in pieces.dropFirst(i + 1) {
                XCTAssertTrue(r.intersection(other).isEmpty || r.intersection(other).isNull)
            }
        }
    }

    func testOverlappingOccludersDoNotExposeTheirOverlap() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pieces = WindowVisibility.pieces(of: frame, excluding: [
            CGRect(x: 0, y: 0, width: 70, height: 100), CGRect(x: 30, y: 0, width: 70, height: 100)
        ])
        XCTAssertTrue(pieces.isEmpty)
    }

    func testOutsideWindowDoesNotChangeVisibleArea() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(WindowVisibility.pieces(of: frame, excluding: [CGRect(x: 120, y: 0, width: 10, height: 10)]), [frame])
    }

    private func row(pid: pid_t, name: String = "App", frame: CGRect, layer: Int = 0) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowOwnerName as String: name,
         kCGWindowBounds as String: ["X": Double(frame.minX), "Y": Double(frame.minY),
                                     "Width": Double(frame.width), "Height": Double(frame.height)],
         kCGWindowLayer as String: layer, kCGWindowAlpha as String: 1.0]
    }

    func testTransparentDockCanvasDoesNotHideAppButFloatingWindowStillDoes() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let app = CGRect(x: 0, y: 34, width: 1186, height: 871)
        let cover = CGRect(x: 100, y: 100, width: 200, height: 200)
        let windows = [row(pid: 99, frame: screen, layer: 1000),
                       row(pid: 2, name: "Dock", frame: screen, layer: 20),
                       row(pid: 3, frame: cover, layer: 3), row(pid: 1, frame: app)]
        let visible = WindowVisibility.visibleRegions(window: app, pid: 1, within: app,
            windowInfo: windows, ownPID: 99, displayFrames: [screen])
        XCTAssertEqual(visible, WindowVisibility.pieces(of: app, excluding: [cover]))
        XCTAssertFalse(visible.isEmpty)
    }

    func testActualDockAndFullScreenAppStillOcclude() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let dock = CGRect(x: 200, y: 900, width: 1000, height: 82)
        let visible = WindowVisibility.visibleRegions(window: screen, pid: 1, within: screen,
            windowInfo: [row(pid: 2, name: "Dock", frame: dock, layer: 20), row(pid: 1, frame: screen)],
            ownPID: 99, displayFrames: [screen])
        XCTAssertEqual(visible, WindowVisibility.pieces(of: screen, excluding: [dock]))
        XCTAssertTrue(WindowVisibility.visibleRegions(window: screen, pid: 1, within: screen,
            windowInfo: [row(pid: 3, frame: screen), row(pid: 1, frame: screen)],
            ownPID: 99, displayFrames: [screen]).isEmpty)
    }

    func testVanishedTargetDoesNotDraw() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(WindowVisibility.visibleRegions(window: frame, pid: 1, within: frame,
            windowInfo: [row(pid: 3, frame: frame)], ownPID: 99, displayFrames: [frame]).isEmpty)
    }
}

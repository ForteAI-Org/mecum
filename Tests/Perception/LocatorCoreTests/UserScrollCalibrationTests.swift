import XCTest
import CoreGraphics
@testable import LocatorCore

/// The watcher's user-gesture px/tick sampler: two scenes around a scroll → pixels moved per wheel
/// line-unit, or nil when the evidence is thin.
final class UserScrollCalibrationTests: XCTestCase {

    func testPaneMotionSurvivesChangingSectionHeaders() {
        let ids = ["row057", "row058", "row059", "row060"]
        let before = scene([0.10, 0.15, 0.20, 0.25], ids: ids, section: "row057")
        let after = scene([0.63, 0.68, 0.73, 0.78], ids: ids, section: "row038")
        XCTAssertNil(UserScrollCalibration.rigidShift(prev: before, now: after, section: "row057"))
        XCTAssertEqual(UserScrollCalibration.rigidShift(prev: before, now: after,
            within: CGRect(x: 0, y: 0, width: 0.3, height: 1)) ?? 0, 0.53, accuracy: 0.001)
    }

    func testGeometricMotionCannotLearnFromAnotherWindow() {
        let ids = ["a", "b", "c"]
        let before = scene([0.1, 0.2, 0.3], ids: ids)
        var after = scene([0.2, 0.3, 0.4], ids: ids)
        after.windowTitle = "Different dialog"
        XCTAssertNil(UserScrollCalibration.rigidShift(prev: before, now: after,
            within: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    func testGeometricMotionExcludesSameNamedRowsInOtherPanes() {
        let ids = ["a", "b", "c"]
        var before = scene([0.1, 0.2, 0.3], ids: ids)
        var after = scene([0.2, 0.3, 0.4], ids: ids)
        for i in 0..<3 {
            var left = before.elements[i], right = after.elements[i]
            left.pos[0] = 0.7; right.pos[0] = 0.7
            before.elements.append(left); after.elements.append(right)
        }
        XCTAssertEqual(UserScrollCalibration.rigidShift(prev: before, now: after,
            within: CGRect(x: 0, y: 0, width: 0.3, height: 1)) ?? 0, 0.1, accuracy: 0.001)
    }

    private func scene(_ ys: [Double], ids: [String], section: String = "sidebar (Channels)") -> SceneSnapshot {
        let els = zip(ids, ys).map { id, y in
            SceneElement(id: id, kind: "text", label: id, pos: [0.05, y, 0.12, 0.02], section: section)
        }
        return SceneSnapshot(bundleID: "test.app", app: "Test", windowTitle: "Main",
                             viewportPx: [2000, 1500], elements: els, sections: [], commands: [])
    }

    func testRigidShiftYieldsSample() {
        // 5 rows all moved up by 0.06 of a 1500px window after 15 wheel units: 90px / 15 = 6 px/tick.
        let ids = ["a", "b", "c", "d", "e"]
        let prev = scene([0.30, 0.35, 0.40, 0.45, 0.50], ids: ids)
        let now = scene([0.24, 0.29, 0.34, 0.39, 0.44], ids: ids)
        let s = UserScrollCalibration.sample(prev: prev, now: now, section: "sidebar (Channels)", wheelUnits: 15)
        XCTAssertEqual(s ?? 0, 6.0, accuracy: 0.01)
    }

    func testDisagreeingMovesYieldNil() {
        // Elements moved in different directions/amounts — no rigid shift, no sample.
        let ids = ["a", "b", "c", "d"]
        let prev = scene([0.30, 0.35, 0.40, 0.45], ids: ids)
        let now = scene([0.24, 0.42, 0.31, 0.52], ids: ids)
        XCTAssertNil(UserScrollCalibration.sample(prev: prev, now: now, section: "sidebar (Channels)", wheelUnits: 15))
    }

    func testTooFewCommonElementsYieldNil() {
        let prev = scene([0.30, 0.35], ids: ["a", "b"])
        let now = scene([0.24, 0.29], ids: ["a", "b"])
        XCTAssertNil(UserScrollCalibration.sample(prev: prev, now: now, section: "sidebar (Channels)", wheelUnits: 15))
    }

    func testTinyGestureYieldsNil() {
        let ids = ["a", "b", "c", "d"]
        let prev = scene([0.30, 0.35, 0.40, 0.45], ids: ids)
        let now = scene([0.24, 0.29, 0.34, 0.39], ids: ids)
        XCTAssertNil(UserScrollCalibration.sample(prev: prev, now: now, section: "sidebar (Channels)", wheelUnits: 2))
    }

    func testHorizontalJitterExcluded() {
        // Same ids but x moved too — layout change (a resize), not a scroll: those pairs don't count.
        let ids = ["a", "b", "c", "d"]
        let prev = scene([0.30, 0.35, 0.40, 0.45], ids: ids)
        var now = scene([0.24, 0.29, 0.34, 0.39], ids: ids)
        now.elements = now.elements.map { e in
            var m = e; m.pos[0] += 0.05; return m
        }
        XCTAssertNil(UserScrollCalibration.sample(prev: prev, now: now, section: "sidebar (Channels)", wheelUnits: 15))
    }

    // MARK: WHICH WAY — the signed reading the wheel's polarity is learned from

    func testRowsMovingDownMeanTheViewWentUp() {
        // Rows at LARGER y than before = they moved down the window = the view revealed what was above
        // them = the view scrolled UP. Positive, by the documented contract.
        let ids = ["a", "b", "c", "d"]
        let prev = scene([0.30, 0.35, 0.40, 0.45], ids: ids)
        let now = scene([0.36, 0.41, 0.46, 0.51], ids: ids)
        let shift = UserScrollCalibration.rigidShift(prev: prev, now: now, section: "sidebar (Channels)")
        XCTAssertNotNil(shift)
        XCTAssertGreaterThan(shift ?? 0, 0)
        XCTAssertEqual(shift ?? 0, 0.06, accuracy: 0.001)
    }

    func testRowsMovingUpMeanTheViewWentDown() {
        let ids = ["a", "b", "c", "d"]
        let prev = scene([0.36, 0.41, 0.46, 0.51], ids: ids)
        let now = scene([0.30, 0.35, 0.40, 0.45], ids: ids)
        XCTAssertLessThan(UserScrollCalibration.rigidShift(prev: prev, now: now, section: "sidebar (Channels)") ?? 0, 0)
    }

    func testTheSignSurvivesTheMagnitudeSample() {
        // The px/tick sample takes the MAGNITUDE, and that is exactly why the direction has its own
        // reading: an `abs` at the source is how a wheel sign gets learned backwards.
        let ids = ["a", "b", "c", "d"]
        let up = UserScrollCalibration.sample(prev: scene([0.30, 0.35, 0.40, 0.45], ids: ids),
                                              now: scene([0.24, 0.29, 0.34, 0.39], ids: ids),
                                              section: "sidebar (Channels)", wheelUnits: 15)
        let down = UserScrollCalibration.sample(prev: scene([0.24, 0.29, 0.34, 0.39], ids: ids),
                                                now: scene([0.30, 0.35, 0.40, 0.45], ids: ids),
                                                section: "sidebar (Channels)", wheelUnits: 15)
        XCTAssertEqual(up ?? 0, 6.0, accuracy: 0.01)
        XCTAssertEqual(down ?? 0, 6.0, accuracy: 0.01)   // same distance, opposite ways
    }

    func testDisagreeingMovesNameNoDirection() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertNil(UserScrollCalibration.rigidShift(prev: scene([0.30, 0.35, 0.40, 0.45], ids: ids),
                                                      now: scene([0.24, 0.42, 0.31, 0.52], ids: ids),
                                                      section: "sidebar (Channels)"))
    }

    func testRepeatedLabelsAreNotMatched() {
        // A file list repeats itself — "4 KB" on three rows, the same date on six. Pairing the first
        // occurrence in one frame with the first in the next pairs DIFFERENT ROWS and invents a
        // confident shift out of nothing (measured on Finder: a list that had just scrolled down read as
        // having gone up). Only names that occur ONCE on both sides are the same thing twice.
        let prev = scene([0.30, 0.35, 0.40, 0.45, 0.50], ids: ["4 KB", "4 KB", "4 KB", "4 KB", "unique"])
        let now = scene([0.24, 0.29, 0.34, 0.39, 0.44], ids: ["4 KB", "4 KB", "4 KB", "4 KB", "unique"])
        XCTAssertNil(UserScrollCalibration.rigidShift(prev: prev, now: now, section: "sidebar (Channels)"),
                     "one unique row is not three agreeing witnesses")
    }

    func testUniqueRowsAmongRepeatsStillCount() {
        let ids = ["dup", "dup", "alpha", "beta", "gamma"]
        let prev = scene([0.30, 0.31, 0.35, 0.40, 0.45], ids: ids)
        let now = scene([0.30, 0.31, 0.29, 0.34, 0.39], ids: ids)
        let shift = UserScrollCalibration.rigidShift(prev: prev, now: now, section: "sidebar (Channels)")
        XCTAssertEqual(shift ?? 0, -0.06, accuracy: 0.001)   // the three unique rows agree: the view went down
    }

    func testSectionFamilyMatchesSuffixVariants() {
        // prev frame said "sidebar (Channels)", the new one "sidebar (Messages)" — same FAMILY, and the
        // family is what the sampler matches on (section headers churn while scrolling).
        let ids = ["a", "b", "c", "d"]
        let prev = scene([0.30, 0.35, 0.40, 0.45], ids: ids, section: "sidebar (Channels)")
        let now = scene([0.24, 0.29, 0.34, 0.39], ids: ids, section: "sidebar (Messages)")
        let s = UserScrollCalibration.sample(prev: prev, now: now, section: "sidebar (Channels)", wheelUnits: 15)
        XCTAssertEqual(s ?? 0, 6.0, accuracy: 0.01)
    }
}

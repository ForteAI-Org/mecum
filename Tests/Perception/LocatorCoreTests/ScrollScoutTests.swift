import XCTest
@testable import LocatorCore

/// ScrollScout: geometry in → scroll evidence out. All synthetic rects are window-normalized, the same
/// space the scene path uses; one test re-runs a case in pixels to prove the scorer is scale-free.
final class ScrollScoutTests: XCTestCase {

    /// A sidebar-like section with `n` aligned rows of `pitch`, first row starting at `top`.
    private func rows(_ n: Int, pitch: Double, top: Double, x: Double = 0.02,
                      w: Double = 0.15, h: Double = 0.02) -> [CGRect] {
        (0..<n).map { CGRect(x: x, y: top + Double($0) * pitch, width: w, height: h) }
    }

    private let sidebar = CGRect(x: 0, y: 0.1, width: 0.2, height: 0.8)

    func testTruncatedListScrolls() {
        // 18 rows, the last one ending a hair from the section bottom — Ron's cue, verbatim.
        let members = rows(18, pitch: 0.044, top: 0.11)   // last row bottom = 0.11+17×0.044+0.02 = 0.878, section bottom 0.9
        let e = ScrollScout.assess(sectionRect: sidebar, memberRects: members)
        XCTAssertTrue(e.likelyScrollsV, e.why)
        XCTAssertTrue(e.moreBelow, e.why)
        XCTAssertEqual(e.listRows, 18)
        XCTAssertEqual(e.rowPitch ?? 0, 0.044, accuracy: 0.001)
    }

    func testShortCompleteListDoesNotScroll() {
        // 5 rows floating in the tall panel with lots of slack below — a complete list, not a viewport.
        let members = rows(5, pitch: 0.05, top: 0.12)
        let e = ScrollScout.assess(sectionRect: sidebar, memberRects: members)
        XCTAssertFalse(e.likelyScrollsV, e.why)
        XCTAssertFalse(e.moreBelow, e.why)
        XCTAssertEqual(e.listRows, 5)
    }

    func testScrolledDownListReportsMoreAbove() {
        // Rows starting right at the top edge and ending with slack — the pane is scrolled down.
        let members = rows(10, pitch: 0.045, top: 0.105)
        let e = ScrollScout.assess(sectionRect: sidebar, memberRects: members)
        XCTAssertTrue(e.moreAbove, e.why)
        XCTAssertTrue(e.likelyScrollsV, e.why)
    }

    func testIrregularPitchIsNotAList() {
        // Same count, chaotic spacing (a form / settings pane).
        var y = 0.12
        var members: [CGRect] = []
        for gap in [0.03, 0.11, 0.05, 0.14, 0.04, 0.12, 0.06] {
            members.append(CGRect(x: 0.02, y: y, width: 0.15, height: 0.02))
            y += gap
        }
        let e = ScrollScout.assess(sectionRect: sidebar, memberRects: members)
        XCTAssertFalse(e.likelyScrollsV, e.why)
    }

    func testTooFewRowsIsNoEvidence() {
        let e = ScrollScout.assess(sectionRect: sidebar, memberRects: rows(3, pitch: 0.05, top: 0.12))
        XCTAssertEqual(e, .none)
    }

    func testMisalignedControlsAreNotAList() {
        // A toolbar-ish scatter: y-regular but x all over the place — the aligned column stays tiny.
        let members = (0..<8).map { CGRect(x: Double($0) * 0.02 + 0.01, y: 0.12 + Double($0) * 0.05,
                                           width: 0.03, height: 0.02) }
        let e = ScrollScout.assess(sectionRect: sidebar, memberRects: members)
        XCTAssertFalse(e.likelyScrollsV, e.why)
    }

    func testIntraRowFragmentsCollapseToOneRow() {
        // Each row = an icon rect + a text rect at the same y (both aligned near the column). The
        // scorer must count ROWS, not fragments — and still see the truncation.
        var members: [CGRect] = []
        for i in 0..<16 {
            let y = 0.11 + Double(i) * 0.049
            members.append(CGRect(x: 0.02, y: y, width: 0.025, height: 0.02))          // icon
            members.append(CGRect(x: 0.032, y: y + 0.002, width: 0.12, height: 0.016)) // caption
        }
        let e = ScrollScout.assess(sectionRect: sidebar, memberRects: members)
        XCTAssertEqual(e.listRows, 16, e.why)
        XCTAssertTrue(e.moreBelow, e.why)
    }

    func testScaleFree_pixelsMatchNormalized() {
        // The exact truncated case, in image pixels (window 3000×2000): verdict must be identical.
        let sectionPx = CGRect(x: 0, y: 200, width: 600, height: 1600)
        let membersPx = (0..<18).map { CGRect(x: 60, y: 220 + Double($0) * 88, width: 450, height: 40) }
        let e = ScrollScout.assess(sectionRect: sectionPx, memberRects: membersPx)
        XCTAssertTrue(e.likelyScrollsV, e.why)
        XCTAssertTrue(e.moreBelow, e.why)
        XCTAssertEqual(e.listRows, 18)
    }

    func testFullListEdgeToEdge() {
        // Rows from top edge to bottom edge: both cues fire, verdict scrolls.
        let members = rows(17, pitch: 0.047, top: 0.104)
        let e = ScrollScout.assess(sectionRect: sidebar, memberRects: members)
        XCTAssertTrue(e.moreAbove && e.moreBelow, e.why)
        XCTAssertTrue(e.likelyScrollsV)
    }

    func testEmptyAndDegenerateInputs() {
        XCTAssertEqual(ScrollScout.assess(sectionRect: sidebar, memberRects: []), .none)
        XCTAssertEqual(ScrollScout.assess(sectionRect: .zero, memberRects: rows(6, pitch: 0.05, top: 0.2)), .none)
    }
}

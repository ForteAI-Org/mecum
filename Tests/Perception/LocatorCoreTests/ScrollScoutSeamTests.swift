import XCTest
@testable import LocatorCore

/// The SECTION CUT IS A MOSAIC: a boundary the list runs straight through is an artifact, not a viewport
/// edge, so the panes either side are one RUN and get judged together. Measured on DaVinci's Project
/// Settings — SectionDetector split ONE aligned category list into two "sidebar (…)" sections, the
/// invented seam carried the whole truncation signature, and the map advertised "scrolls ↓ (more below)"
/// on a pane nothing can scroll (the lie was then learned). Measured on Finder the other way — a real
/// truncation landing in a 0.08-tall bottom tile only survives because the run is judged whole.
final class ScrollScoutSeamTests: XCTestCase {

    /// `n` aligned rows of `pitch`, first row top at `top` — one column, sidebar-shaped.
    private func rows(_ n: Int, pitch: Double, top: Double, x: Double = 0.02,
                      w: Double = 0.15, h: Double = 0.02) -> [CGRect] {
        (0..<n).map { CGRect(x: x, y: top + Double($0) * pitch, width: w, height: h) }
    }

    private func pane(_ rect: CGRect, _ members: [CGRect], _ family: String? = "sidebar") -> ScrollScout.Pane {
        ScrollScout.Pane(rect: rect, members: members, family: family)
    }

    // The DaVinci geometry: one 0.8-tall sidebar list cut in two at y = 0.5, with slack below the last
    // row — a complete list that only LOOKS truncated because of where the cut fell.
    private let upper = CGRect(x: 0, y: 0.1, width: 0.2, height: 0.4)
    private let lower = CGRect(x: 0, y: 0.5, width: 0.2, height: 0.4)
    private let pitch = 0.044
    private var upperRows: [CGRect] { rows(9, pitch: pitch, top: 0.125) }   // last bottom 0.497 — at the cut
    private var lowerRows: [CGRect] { rows(5, pitch: pitch, top: 0.506) }   // ends 0.702, then 0.2 of slack

    func testACutListIsJudgedWholeAndStaysSilent() {
        // Judged as a tile, the upper half is textbook truncation — that is the bug being fixed.
        let tile = ScrollScout.assess(sectionRect: upper, memberRects: upperRows)
        XCTAssertTrue(tile.moreBelow && tile.likelyScrollsV,
                      "precondition: the tile alone does read as truncated — \(tile.why)")

        let panes = [pane(upper, upperRows), pane(lower, lowerRows)]
        for i in panes.indices {
            let e = ScrollScout.assess(paneAt: i, in: panes)
            XCTAssertFalse(e.likelyScrollsV, "pane \(i) must not advertise scrolling — \(e.why)")
            XCTAssertFalse(e.moreBelow, "pane \(i) — \(e.why)")
            XCTAssertEqual(e.listRows, 14, "the run sees the WHOLE list, not its tile")
        }
    }

    /// The other half of the trade: a list truncated by the REAL window edge keeps its claim even when
    /// the cut leaves the truncation in a tiny bottom tile too small to speak for itself. (Finder,
    /// live: a 920×300 window whose sidebar split into 0.81 / 0.10 / 0.08 tall tiles.)
    func testRealTruncationSurvivesTheCut() {
        let big = CGRect(x: 0, y: 0, width: 0.2, height: 0.81)
        let mid = CGRect(x: 0, y: 0.81, width: 0.2, height: 0.11)
        let tail = CGRect(x: 0, y: 0.92, width: 0.2, height: 0.08)
        let panes = [pane(big, rows(18, pitch: 0.045, top: 0.02)),   // 0.02 … 0.805
                     pane(mid, rows(2, pitch: 0.045, top: 0.83)),    // 0.83 … 0.895
                     pane(tail, rows(2, pitch: 0.045, top: 0.92))]   // … 0.985, hard against the window edge
        let e = ScrollScout.assess(paneAt: 0, in: panes)
        XCTAssertTrue(e.moreBelow, e.why)
        XCTAssertTrue(e.likelyScrollsV, e.why)
        XCTAssertEqual(e.listRows, 22, "all three tiles are one list — \(e.why)")
    }

    /// The run walks as far as the list goes: three tiles collapse in two steps.
    func testTheRunGrowsThroughMoreThanOneCut() {
        let a = CGRect(x: 0, y: 0.1, width: 0.2, height: 0.25)
        let b = CGRect(x: 0, y: 0.35, width: 0.2, height: 0.25)
        let c = CGRect(x: 0, y: 0.60, width: 0.2, height: 0.30)
        let panes = [pane(a, rows(5, pitch: pitch, top: 0.125)),   // 0.125 … 0.321
                     pane(b, rows(6, pitch: pitch, top: 0.355)),   // 0.355 … 0.595
                     pane(c, rows(4, pitch: pitch, top: 0.606))]   // 0.606 … 0.758, slack to 0.9
        let e = ScrollScout.assess(paneAt: 0, in: panes)
        XCTAssertEqual(e.listRows, 15, "all three tiles joined — \(e.why)")
        XCTAssertFalse(e.likelyScrollsV, e.why)
        XCTAssertTrue(e.why.contains("across 3 stacked panes"), "the merge is stated honestly — \(e.why)")
    }

    /// A RIGHT-aligned list continues across the cut too — DaVinci's category list is right-aligned, and
    /// its widest row ("Subtitles and Transcription") is the very one that lands past the boundary, so a
    /// left-edge-only continuity test misses exactly the case that mattered.
    func testRightAlignedListsContinueAcrossTheCut() {
        let right = 0.18
        let upperR = (0..<9).map { i -> CGRect in
            let w = 0.10 + Double(i % 3) * 0.02
            return CGRect(x: right - w, y: 0.125 + Double(i) * pitch, width: w, height: 0.02)
        }
        let lowerR = (0..<5).map { i -> CGRect in
            let w = i == 0 ? 0.17 : 0.09      // the widest row lands first, past the cut
            return CGRect(x: right - w, y: 0.506 + Double(i) * pitch, width: w, height: 0.02)
        }
        let panes = [pane(upper, upperR), pane(lower, lowerR)]
        let e = ScrollScout.assess(paneAt: 0, in: panes)
        XCTAssertFalse(e.likelyScrollsV, "the right-aligned list is one run — \(e.why)")
        XCTAssertTrue(e.why.contains("across 2 stacked panes"), e.why)
    }

    // MARK: what must NOT join a run

    /// A neighbour whose first row sits pitches away is a SEPARATE panel with its own padding.
    func testDistantNeighbourIsNotTheSameList() {
        let panes = [pane(upper, upperRows), pane(lower, rows(5, pitch: pitch, top: 0.62))]
        let e = ScrollScout.assess(paneAt: 0, in: panes)
        XCTAssertTrue(e.moreBelow, e.why)
        XCTAssertTrue(e.likelyScrollsV, e.why)
        XCTAssertEqual(e.listRows, 9, "the run stops at the real boundary")
    }

    /// A neighbour in a different COLUMN (an indented sub-panel, a form field) is not this list either.
    func testMisalignedNeighbourIsNotTheSameList() {
        let panes = [pane(upper, upperRows), pane(lower, rows(5, pitch: pitch, top: 0.506, x: 0.12))]
        let e = ScrollScout.assess(paneAt: 0, in: panes)
        XCTAssertTrue(e.likelyScrollsV, e.why)
        XCTAssertEqual(e.listRows, 9)
    }

    /// A pane SIDE BY SIDE shares a vertical edge, not a horizontal one — never part of the run.
    func testSideBySidePanesNeverJoin() {
        let panes = [pane(upper, upperRows),
                     pane(CGRect(x: 0.2, y: 0.1, width: 0.8, height: 0.4), lowerRows)]
        XCTAssertEqual(ScrollScout.assess(paneAt: 0, in: panes).listRows, 9)
    }

    /// Different families stacked (a sidebar over a bottom bar) are a REAL boundary.
    func testADifferentFamilyNeverJoins() {
        let panes = [pane(upper, upperRows), pane(lower, lowerRows, "bottom bar")]
        let e = ScrollScout.assess(paneAt: 0, in: panes)
        XCTAssertTrue(e.likelyScrollsV, "a real panel boundary below still truncates — \(e.why)")
        XCTAssertEqual(e.listRows, 9)
    }

    /// Panes that merely float near each other (a real gap between panels) do not abut.
    func testDetachedPanesNeverJoin() {
        let detached = CGRect(x: 0, y: 0.56, width: 0.2, height: 0.34)
        let panes = [pane(upper, upperRows), pane(detached, rows(5, pitch: pitch, top: 0.566))]
        XCTAssertEqual(ScrollScout.assess(paneAt: 0, in: panes).listRows, 9)
    }

    func testDegenerateInput() {
        let panes = [pane(.zero, []), pane(upper, upperRows)]
        XCTAssertEqual(ScrollScout.assess(paneAt: 0, in: panes), .none)
        XCTAssertEqual(ScrollScout.assess(paneAt: 9, in: panes), .none)
        XCTAssertEqual(ScrollScout.assess(paneAt: 1, in: panes).listRows, 9, "a zero-rect pane joins nothing")
    }
}

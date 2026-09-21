import XCTest
import CoreGraphics
import OCRSupport
@testable import Relocation

final class IncrementalOCRPlanTests: XCTestCase {
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testDirtyTileGrowsToTheWholeLineItTouches() {
        // A 600px-wide label spans tiles 1..5; only tile (2,1) changed.
        let line = OCRResult(text: "Align Clips to Frame Boundaries", boxImagePx: CGRect(x: 150, y: 170, width: 600, height: 20))
        let far = OCRResult(text: "Cancel", boxImagePx: CGRect(x: 800, y: 500, width: 60, height: 20))
        let (rects, kept) = IncrementalOCR.plan(dirty: [CGRect(x: 256, y: 128, width: 128, height: 128)], previous: [line, far], frame: frame)
        XCTAssertEqual(rects.count, 1)
        XCTAssertTrue(rects[0].contains(line.boxImagePx), "the whole line is re-read, never a fragment: \(rects[0])")
        XCTAssertEqual(kept, [far], "untouched runs survive verbatim; the touched line is dropped for re-reading")
    }

    func testTouchingRectsMergeAndAreaIsBounded() {
        let (rects, _) = IncrementalOCR.plan(dirty: [CGRect(x: 0, y: 0, width: 128, height: 128), CGRect(x: 128, y: 0, width: 128, height: 128)],
                                             previous: [], frame: frame)
        XCTAssertEqual(rects.count, 1)
        let pad = IncrementalOCR.pads(lineHeight: 24)
        XCTAssertEqual(rects[0], CGRect(x: 0, y: 0, width: 256 + pad.h, height: 128 + pad.v), "padded by the default line, clipped to the frame")
    }

    func testNoPreviousRunsKeepsNothingAndReadsPaddedTiles() {
        let (rects, kept) = IncrementalOCR.plan(dirty: [CGRect(x: 512, y: 256, width: 128, height: 128)], previous: [], frame: frame)
        XCTAssertEqual(kept, [])
        let pad = IncrementalOCR.pads(lineHeight: 24)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, 512 - pad.h, accuracy: 0.01); XCTAssertEqual(rects[0].minY, 256 - pad.v, accuracy: 0.01)
        XCTAssertEqual(rects[0].width, 128 + 2 * pad.h, accuracy: 0.01); XCTAssertEqual(rects[0].height, 128 + 2 * pad.v, accuracy: 0.01)
    }

    func testGrowthFollowsTheLineNotTheColumn() {
        // Six stacked 20px lines, 28px apart (spacing 1.4, gap 8); the dirty tile spans y 128…256.
        let lines = (0..<6).map { OCRResult(text: "line \($0)", boxImagePx: CGRect(x: 100, y: 80 + 28 * $0, width: 400, height: 20)) }
        let dirty = [CGRect(x: 128, y: 128, width: 128, height: 128)]
        let (rects, kept) = IncrementalOCR.plan(dirty: dirty, previous: lines, frame: frame)
        XCTAssertEqual(rects.count, 1)
        // Lines 1–5 intersect the padded tile and are re-read whole; line 0 (y 80–100) sits above it and the
        // 7px vertical pad (0.35 × 20) is smaller than the 8px line gap, so growth stops at line 1.
        XCTAssertEqual(kept.map(\.text), ["line 0"], "the vertical pad must not cascade to the line above: \(rects[0])")
    }
}

/// The cost guard's second term (scene-service issue 09). Area alone cannot see the case where many
/// small scattered crops cost more than one full read.
final class IncrementalOCRRectCountGuardTests: XCTestCase {
    let frame = CGRect(x: 0, y: 0, width: 2000, height: 1400)

    /// Twelve one-line changes scattered down a column: tiny total area, many crops.
    private func scatteredLines(_ n: Int) -> (dirty: [CGRect], previous: [OCRResult]) {
        var dirty: [CGRect] = []
        var prev: [OCRResult] = []
        for i in 0..<n {
            let y = CGFloat(40 + i * 100)
            prev.append(OCRResult(text: "row \(i)", boxImagePx: CGRect(x: 60, y: y, width: 220, height: 18)))
            dirty.append(CGRect(x: 64, y: y, width: 64, height: 64))
        }
        return (dirty, prev)
    }

    func testManyScatteredRectsStayCheapInAreaButNumerous() {
        let (dirty, prev) = scatteredLines(12)
        let (rects, _) = IncrementalOCR.plan(dirty: dirty, previous: prev, frame: frame)
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) } / Double(frame.width * frame.height)

        // This is precisely the blind spot: WELL under the 0.6 area cutoff, yet more crops than the
        // measured 8-10 break-even, so the area-only guard would have taken the expensive path.
        XCTAssertLessThan(area, IncrementalOCR.maxPartialArea,
                          "area alone would have allowed the partial path")
        XCTAssertGreaterThan(rects.count, IncrementalOCR.maxPartialRects,
                             "…while the rect count is what makes it expensive")
    }

    func testAFewRectsAreStillWithinTheGuard() {
        let (dirty, prev) = scatteredLines(3)
        let (rects, _) = IncrementalOCR.plan(dirty: dirty, previous: prev, frame: frame)
        XCTAssertLessThanOrEqual(rects.count, IncrementalOCR.maxPartialRects,
                                 "the common case — a few changed lines — must keep the incremental path")
    }

    func testTheCutoffSitsAboveTheMeasuredBreakEven() {
        // Ticket 09 measured a 17-20 ms floor per crop with break-even at ~8-10 rects. A cutoff below
        // that would send ordinary edits down the full-read path and undo the incremental win.
        XCTAssertGreaterThanOrEqual(IncrementalOCR.maxPartialRects, 8)
    }
}

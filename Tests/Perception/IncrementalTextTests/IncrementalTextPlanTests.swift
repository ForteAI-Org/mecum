//
//  IncrementalTextPlanTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import PerceptionCore
import XCTest
@testable import IncrementalText

/// What a dirty tile grows into: never a fragment of a line, never the column above it.
final class IncrementalTextPlanTests: XCTestCase {

    let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testDirtyTileGrowsToTheWholeLineItTouches() {
        // A 600 pixel label spans tiles 1 to 5; only tile (2,1) changed.
        let line = RecognizedText(text: "Align Clips to Frame Boundaries",
                                  pixelBox: CGRect(x: 150, y: 170, width: 600, height: 20))
        let far = RecognizedText(text: "Cancel", pixelBox: CGRect(x: 800, y: 500, width: 60, height: 20))
        let (rects, kept) = IncrementalTextPlan.plan(
            dirty: [CGRect(x: 256, y: 128, width: 128, height: 128)], previous: [line, far], frame: frame
        )
        XCTAssertEqual(rects.count, 1)
        XCTAssertTrue(rects[0].contains(line.pixelBox), "the whole line is read again, never a fragment: \(rects[0])")
        XCTAssertEqual(kept, [far], "untouched runs survive verbatim; the touched line is dropped for re-reading")
    }

    func testTouchingRectsMergeAndAreaIsBounded() {
        let (rects, _) = IncrementalTextPlan.plan(
            dirty: [CGRect(x: 0, y: 0, width: 128, height: 128), CGRect(x: 128, y: 0, width: 128, height: 128)],
            previous: [], frame: frame
        )
        XCTAssertEqual(rects.count, 1)
        let pad = IncrementalTextPlan.pads(lineHeight: 24)
        XCTAssertEqual(rects[0], CGRect(x: 0, y: 0, width: 256 + pad.horizontal, height: 128 + pad.vertical),
                       "padded by the default line, clipped to the frame")
    }

    func testNoPreviousRunsKeepsNothingAndReadsPaddedTiles() {
        let (rects, kept) = IncrementalTextPlan.plan(
            dirty: [CGRect(x: 512, y: 256, width: 128, height: 128)], previous: [], frame: frame
        )
        XCTAssertEqual(kept, [])
        let pad = IncrementalTextPlan.pads(lineHeight: 24)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, 512 - pad.horizontal, accuracy: 0.01)
        XCTAssertEqual(rects[0].minY, 256 - pad.vertical, accuracy: 0.01)
        XCTAssertEqual(rects[0].width, 128 + 2 * pad.horizontal, accuracy: 0.01)
        XCTAssertEqual(rects[0].height, 128 + 2 * pad.vertical, accuracy: 0.01)
    }

    func testGrowthFollowsTheLineNotTheColumn() {
        // Six stacked 20 pixel lines, 28 pixels apart (spacing 1.4, gap 8); the dirty tile spans y 128 to 256.
        let lines = (0..<6).map {
            RecognizedText(text: "line \($0)", pixelBox: CGRect(x: 100, y: 80 + 28 * $0, width: 400, height: 20))
        }
        let (rects, kept) = IncrementalTextPlan.plan(
            dirty: [CGRect(x: 128, y: 128, width: 128, height: 128)], previous: lines, frame: frame
        )
        XCTAssertEqual(rects.count, 1)
        // Lines 1 to 5 intersect the padded tile and are read whole; line 0 (y 80 to 100) sits above it
        // and the 7 pixel vertical pad (0.35 x 20) is smaller than the 8 pixel line gap, so growth stops.
        XCTAssertEqual(kept.map(\.text), ["line 0"],
                       "the vertical pad must not cascade to the line above: \(rects[0])")
    }
}

/// The cost guard's second term: area alone cannot see the case where many small scattered crops
/// cost more than one full read.
final class IncrementalTextRectCountGuardTests: XCTestCase {

    let frame = CGRect(x: 0, y: 0, width: 2000, height: 1400)

    /// One-line changes scattered down a column: tiny total area, many crops.
    private func scatteredLines(_ count: Int) -> (dirty: [CGRect], previous: [RecognizedText]) {
        var dirty: [CGRect] = []
        var previous: [RecognizedText] = []
        for index in 0..<count {
            let y = CGFloat(40 + index * 100)
            previous.append(RecognizedText(text: "row \(index)",
                                           pixelBox: CGRect(x: 60, y: y, width: 220, height: 18)))
            dirty.append(CGRect(x: 64, y: y, width: 64, height: 64))
        }
        return (dirty, previous)
    }

    func testManyScatteredRectsStayCheapInAreaButNumerous() {
        let (dirty, previous) = scatteredLines(12)
        let (rects, _) = IncrementalTextPlan.plan(dirty: dirty, previous: previous, frame: frame)
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) } / Double(frame.width * frame.height)

        // Precisely the blind spot: well under the area cutoff, yet more crops than the measured
        // break-even, so an area-only guard would have taken the expensive path.
        XCTAssertLessThan(area, IncrementalTextPlan.maxPartialArea, "area alone would have allowed the partial path")
        XCTAssertGreaterThan(rects.count, IncrementalTextPlan.maxPartialRects,
                             "while the rect count is what makes it expensive")
        XCTAssertTrue(IncrementalTextPlan.prefersFullRead(rects: rects, in: frame))
    }

    func testAFewRectsAreStillWithinTheGuard() {
        let (dirty, previous) = scatteredLines(3)
        let (rects, _) = IncrementalTextPlan.plan(dirty: dirty, previous: previous, frame: frame)
        XCTAssertLessThanOrEqual(rects.count, IncrementalTextPlan.maxPartialRects,
                                 "the common case, a few changed lines, must keep the incremental path")
        XCTAssertFalse(IncrementalTextPlan.prefersFullRead(rects: rects, in: frame))
    }

    func testTheCutoffSitsAboveTheMeasuredBreakEven() {
        // The measured 17 to 20 ms floor per crop breaks even at about eight to ten rects. A cutoff
        // below that would send ordinary edits down the full-read path and undo the incremental win.
        XCTAssertGreaterThanOrEqual(IncrementalTextPlan.maxPartialRects, 8)
    }
}

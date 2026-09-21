import XCTest
import CoreGraphics
@testable import Relocation

/// Candidate ranking for section-anchored reach, pinned to the REAL geometry of the two frozen
/// fixtures (~/.fflow/fixtures) — the shapes sections v2 actually produces.
final class ScrollCandidateTests: XCTestCase {
    private let img = CGSize(width: 2594, height: 1726)   // the Slack fixture's pixel size

    func testSlackGeometryRanksSidebarBeforeContentThenWindowLast() {
        // nav rail (0.06×1.00) · sidebar list (0.20×0.71) · content band (0.74×0.31) · bottom bar (thin)
        let rects = [CGRect(x: 0, y: 0, width: 156, height: 1726),
                     CGRect(x: 156, y: 500, width: 519, height: 1226),
                     CGRect(x: 675, y: 794, width: 1919, height: 535),
                     CGRect(x: 675, y: 1519, width: 1919, height: 207)]
        let c = KBReacher.scrollCandidates(sectionRectsPx: rects, imagePixelSize: img)
        XCTAssertEqual(c.map(\.name), ["nav rail", "sidebar", "content", "window"])
        XCTAssertEqual(c.last!.bounds, CGRect(x: 0, y: 0, width: 1, height: 1))
        // the bottom bar (thin strip) must never become a scroll candidate
        XCTAssertFalse(c.contains { $0.bounds.height < 0.25 && $0.name != "window" })
    }

    func testNoSectionsStillYieldsTheLegacyWindowContainer() {
        let c = KBReacher.scrollCandidates(sectionRectsPx: [], imagePixelSize: img)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].name, "window")
    }

    func testCalibratedSeedTicksAimsShortAndClamps() {
        // 10 rows away, pitch 0.036 of a 1726px window, pane moves ~30px/tick, 12 events/step:
        // desired ≈ 10·0.036·1726·0.8 = 497px ; ticks ≈ 497/(30·12) ≈ 1.38 → 1
        let t = KBReacher.calibratedSeedTicks(rowsAway: 10, pitchNorm: 0.036, windowHpx: 1726,
                                              pxPerTick: 30, eventsPerStep: 12)
        XCTAssertEqual(t, 1)
        // a slow pane (2px/tick) far away needs a bigger jump, but clamps at 6
        let big = KBReacher.calibratedSeedTicks(rowsAway: 40, pitchNorm: 0.036, windowHpx: 1726,
                                                pxPerTick: 2, eventsPerStep: 12)
        XCTAssertEqual(big, 6)
        // near targets (<3 rows) don't calibrate — the default gentle seed handles them
        XCTAssertNil(KBReacher.calibratedSeedTicks(rowsAway: 2, pitchNorm: 0.036, windowHpx: 1726,
                                                   pxPerTick: 30, eventsPerStep: 12))
        // missing measurements → nil (never guess)
        XCTAssertNil(KBReacher.calibratedSeedTicks(rowsAway: 10, pitchNorm: 0, windowHpx: 1726,
                                                   pxPerTick: 30, eventsPerStep: 12))
    }

    func testFullWindowSectionIsNotDuplicated() {
        // a single near-full-window section (simple app) must not add a duplicate of the fallback
        let c = KBReacher.scrollCandidates(
            sectionRectsPx: [CGRect(origin: .zero, size: CGSize(width: 2594, height: 1726))],
            imagePixelSize: img)
        XCTAssertEqual(c.map(\.name), ["window"])
    }

    func testScrollEvidenceOutranksNarrowGeometry() {
        // Two tall panels: a NARROW one holding sparse scattered text (no list), and a WIDE one holding
        // a regular list whose last row runs into the panel's bottom edge (Ron's cue). Geometry alone
        // would probe the narrow one first; evidence must put the truncated list first.
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 1726)
        let wide = CGRect(x: 400, y: 0, width: 1400, height: 1726)
        var boxes: [CGRect] = []
        for i in 0..<20 { boxes.append(CGRect(x: 460, y: 40 + Double(i) * 85, width: 500, height: 36)) }   // wide: list to the edge
        boxes.append(CGRect(x: 40, y: 100, width: 200, height: 30))                                        // narrow: stray text
        boxes.append(CGRect(x: 80, y: 900, width: 150, height: 30))
        let c = KBReacher.scrollCandidates(sectionRectsPx: [narrow, wide], imagePixelSize: img, ocrBoxesPx: boxes)
        XCTAssertTrue(c[0].evidence.likelyScrollsV, c[0].evidence.why)
        XCTAssertEqual(c[0].bounds.minX, 400 / 2594, accuracy: 0.001)
        XCTAssertTrue(c[0].evidence.moreBelow, c[0].evidence.why)
        XCTAssertFalse(c[1].evidence.likelyScrollsV)
    }

    func testNoOcrBoxesFallsBackToGeometryOrder() {
        // Without member boxes the evidence is silent everywhere → the shipped narrow-first order holds.
        let rects = [CGRect(x: 156, y: 500, width: 519, height: 1226),
                     CGRect(x: 675, y: 0, width: 1919, height: 1726)]
        let c = KBReacher.scrollCandidates(sectionRectsPx: rects, imagePixelSize: img)
        XCTAssertEqual(c.first?.bounds.width ?? 0, 519 / 2594, accuracy: 0.001)
        XCTAssertTrue(c.allSatisfy { !$0.evidence.likelyScrollsV })
    }
}

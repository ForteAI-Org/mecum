import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

final class TextConstellationTests: XCTestCase {
    func testFuzzyMatch() {
        XCTAssertTrue(TextConstellation.matches("Audi1", "Audio 1"))   // OCR noise
        XCTAssertTrue(TextConstellation.matches("Bold", "bold"))
        XCTAssertTrue(TextConstellation.matches("Vox Lead", "Vox Lead"))
        XCTAssertFalse(TextConstellation.matches("Bold", "Italic"))
        XCTAssertFalse(TextConstellation.matches("", "x"))
    }

    func testIdentityMatchDistinguishesNearIdenticalLabels() {
        // The look-alike guard: a one-digit difference in a short label is a DIFFERENT element.
        XCTAssertFalse(TextConstellation.identityMatches("Audio 5", "Audio 6"))
        XCTAssertFalse(TextConstellation.identityMatches("Audio 7", "Audio 9"))
        XCTAssertFalse(TextConstellation.identityMatches("Audio 10", "Audio 11"))
        // Same identity, tolerant of spacing/case + trailing junk + a slip in a long label.
        XCTAssertTrue(TextConstellation.identityMatches("Audio 5", "Audio 5"))
        XCTAssertTrue(TextConstellation.identityMatches("Sfx1", "Sfx 1"))
        XCTAssertTrue(TextConstellation.identityMatches("Master Settings", "Master Setting5"))
        // (Contrast: plain fuzzy `matches` WOULD conflate the look-alikes — that's the bug we guard.)
        XCTAssertTrue(TextConstellation.matches("Audio 5", "Audio 6"))
    }

    func testLocateFindsSelfTextWithNeighbors() {
        let selfBox = CGRect(x: 100, y: 100, width: 40, height: 20)
        let neighbor = TextNeighbor(text: "Mute", offset: CGPoint(x: 50, y: 0), tolerancePx: 8)
        let runs: [(text: String, box: CGRect)] = [
            ("Vox Lead", selfBox),
            ("Mute", CGRect(x: 152, y: 100, width: 30, height: 18)),   // ≈ origin + (50,0)
            ("Other", CGRect(x: 500, y: 500, width: 20, height: 20)),
        ]
        let located = TextConstellation.locate(selfText: "Vox Lead", neighbors: [neighbor], offsetScale: 1, tolerancePadPx: 10, runs: runs)
        XCTAssertEqual(located?.box, selfBox)
        XCTAssertEqual(located?.neighborFraction, 1.0)
    }

    func testLocateLowerFractionWhenNeighborMissing() {
        let selfBox = CGRect(x: 100, y: 100, width: 40, height: 20)
        let neighbors = [
            TextNeighbor(text: "Mute", offset: CGPoint(x: 50, y: 0), tolerancePx: 8),
            TextNeighbor(text: "Solo", offset: CGPoint(x: 90, y: 0), tolerancePx: 8),
        ]
        let runs: [(text: String, box: CGRect)] = [
            ("Vox Lead", selfBox),
            ("Mute", CGRect(x: 152, y: 100, width: 30, height: 18)),   // Solo absent
        ]
        let located = TextConstellation.locate(selfText: "Vox Lead", neighbors: neighbors, offsetScale: 1, tolerancePadPx: 10, runs: runs)
        XCTAssertEqual(located?.neighborFraction, 0.5)
    }

    func testLocateReturnsNilWhenNoSelfTextMatch() {
        let runs: [(text: String, box: CGRect)] = [("Foo", CGRect(x: 0, y: 0, width: 10, height: 10))]
        XCTAssertNil(TextConstellation.locate(selfText: "Vox Lead", neighbors: [], offsetScale: 1, tolerancePadPx: 10, runs: runs))
    }

    func testOffsetScaleAppliesToNeighborExpectation() {
        // At 2× scale, a neighbor stored at offset (50,0) is expected at origin + (100,0).
        let selfBox = CGRect(x: 100, y: 100, width: 40, height: 20)
        let neighbor = TextNeighbor(text: "Mute", offset: CGPoint(x: 50, y: 0), tolerancePx: 8)
        let runs: [(text: String, box: CGRect)] = [
            ("Vox", selfBox),
            ("Mute", CGRect(x: 200, y: 100, width: 30, height: 18)),
        ]
        let located = TextConstellation.locate(selfText: "Vox", neighbors: [neighbor], offsetScale: 2, tolerancePadPx: 10, runs: runs)
        XCTAssertEqual(located?.neighborFraction, 1.0)
    }

    func testLocatePrefersExactSelfTextOverSubstring() {
        // "Audio 1" is a substring of "Audio 11"/"Audio 12"; locate must resolve to the EXACT run,
        // not the first substring-containing one (the duplicate-label self-heal corruption guard).
        let exactBox = CGRect(x: 100, y: 100, width: 40, height: 16)
        let runs: [(text: String, box: CGRect)] = [
            ("Audio 11", CGRect(x: 100, y: 200, width: 48, height: 16)),
            ("Audio 1", exactBox),
            ("Audio 12", CGRect(x: 100, y: 300, width: 48, height: 16)),
        ]
        let located = TextConstellation.locate(selfText: "Audio 1", neighbors: [], offsetScale: 1, tolerancePadPx: 10, runs: runs)
        XCTAssertEqual(located?.box, exactBox)
    }

    func testLocateByNeighborsTriangulatesFromStableLabels() {
        // Element origin is (200,100). Two stable neighbors at known relative offsets; the element's own
        // value text ("1828 x 1332 Academy") is present but is NOT used — we anchor on the neighbors.
        let neighbors = [
            TextNeighbor(text: "Timeline resolution", offset: CGPoint(x: -150, y: 0), tolerancePx: 8),
            TextNeighbor(text: "processing", offset: CGPoint(x: -10, y: 40), tolerancePx: 8),
        ]
        let runs: [(text: String, box: CGRect)] = [
            ("Timeline resolution", CGRect(x: 50, y: 100, width: 120, height: 16)),   // → element (200,100)
            ("1828 x 1332 Academy", CGRect(x: 200, y: 100, width: 90, height: 16)),
            ("processing", CGRect(x: 190, y: 140, width: 70, height: 16)),            // → element (200,100)
        ]
        let anchored = TextConstellation.locateByNeighbors(
            neighbors: neighbors, offsetScale: 1, tolerancePadPx: 6,
            elementSizePx: CGSize(width: 90, height: 16), minAgree: 2, runs: runs)
        XCTAssertEqual(anchored?.box.origin.x ?? -1, 200, accuracy: 2)
        XCTAssertEqual(anchored?.box.origin.y ?? -1, 100, accuracy: 2)
        XCTAssertEqual(anchored?.anchorFraction ?? 0, 1.0)
    }

    func testLocateByNeighborsPrefersTighterClusterOnDistinctTie() {
        // Two clusters both reach distinct=2. The spurious one (encountered first in vote order) is loose;
        // the true one is tight. The winner must be the tight cluster, not the first-seen one.
        let neighbors = [
            TextNeighbor(text: "alpha", offset: CGPoint(x: -100, y: 0), tolerancePx: 8),
            TextNeighbor(text: "beta", offset: CGPoint(x: 0, y: -100), tolerancePx: 8),
        ]
        // Spurious: alpha→(100,100), beta→(118,100) (18px apart, both within clusterTol=40 → distinct 2, loose).
        // True:     alpha→(500,500), beta→(500,500) (coincident → distinct 2, spread 0).
        let runs: [(text: String, box: CGRect)] = [
            ("alpha", CGRect(x: 0, y: 100, width: 30, height: 12)),     // → (100,100)
            ("beta", CGRect(x: 118, y: 0, width: 30, height: 12)),      // → (118,100)
            ("alpha", CGRect(x: 400, y: 500, width: 30, height: 12)),   // → (500,500)
            ("beta", CGRect(x: 500, y: 400, width: 30, height: 12)),    // → (500,500)
        ]
        let anchored = TextConstellation.locateByNeighbors(
            neighbors: neighbors, offsetScale: 1, tolerancePadPx: 24,
            elementSizePx: CGSize(width: 40, height: 16), minAgree: 2, runs: runs)
        XCTAssertEqual(anchored?.box.origin.x ?? -1, 500, accuracy: 2)   // the TIGHT cluster, not (100,100)
        XCTAssertEqual(anchored?.box.origin.y ?? -1, 500, accuracy: 2)
    }

    func testLocateByNeighborsIgnoresGenericRepeatingNeighbors() {
        // "wave" recurs on every track row → it can't pin a position and must be ignored; only the
        // unique "Audio 5" is discriminating, which alone is below minAgree → nil (honest miss, not a
        // confident wrong row — this is the "Audio 4 → Audio 6" bug).
        let neighbors = [
            TextNeighbor(text: "wave", offset: CGPoint(x: 40, y: 0), tolerancePx: 8),
            TextNeighbor(text: "Audio 5", offset: CGPoint(x: 0, y: 60), tolerancePx: 8),
        ]
        var runs: [(text: String, box: CGRect)] = [("Audio 5", CGRect(x: 100, y: 160, width: 40, height: 16))]
        for r in 0..<8 { runs.append(("wave", CGRect(x: 60, y: 100 + r * 120, width: 30, height: 12))) }   // 8 rows
        let anchored = TextConstellation.locateByNeighbors(
            neighbors: neighbors, offsetScale: 1, tolerancePadPx: 6,
            elementSizePx: CGSize(width: 40, height: 16), minAgree: 2, runs: runs)
        XCTAssertNil(anchored)
    }

    func testUniqueNeighborSupportRejectsGenericOnlyAnchor() {
        // The "Audio 3" → clicked "Audio 28" false positive: the target is off-screen, so its only
        // present neighbors are the per-row layout ("wave"/"S"/"M") that repeats identically on EVERY row.
        // A box triangulated from those has NO globally-unique neighbor at its expected offset → reject.
        let box = CGRect(x: 305, y: 1106, width: 89, height: 23)
        let neighbors = [
            TextNeighbor(text: "wave", offset: CGPoint(x: 13, y: 85), tolerancePx: 12),
            TextNeighbor(text: "M", offset: CGPoint(x: 120, y: 41), tolerancePx: 12),
            TextNeighbor(text: "Audio 2", offset: CGPoint(x: 0, y: -122), tolerancePx: 12),   // off-screen → absent
            TextNeighbor(text: "Audio 4", offset: CGPoint(x: 0, y: 123), tolerancePx: 12),    // off-screen → absent
        ]
        // Frame shows Audio 24–30: wave/M repeat on every row (not unique); Audio 2/4 absent.
        var runs: [(text: String, box: CGRect)] = []
        for r in 0..<7 {
            runs.append(("wave", CGRect(x: 318, y: 1191 + r * 120, width: 30, height: 12)))
            runs.append(("M", CGRect(x: 425, y: 1147 + r * 120, width: 16, height: 12)))
            runs.append(("Audio \(24 + r)", CGRect(x: 305, y: 1106 + r * 120, width: 89, height: 23)))
        }
        XCTAssertFalse(TextConstellation.hasUniqueNeighborSupport(box: box, neighbors: neighbors,
                                                                 offsetScale: 1, tolerancePadPx: 24, runs: runs))
    }

    func testUniqueNeighborSupportAcceptsWhenDiscriminatingNeighborPresent() {
        // The legitimate cases: a dropdown's unique field label, or an adjacent track number that IS on
        // screen, sits at its expected offset → trustworthy anchor.
        let box = CGRect(x: 200, y: 100, width: 90, height: 16)
        let neighbors = [
            TextNeighbor(text: "wave", offset: CGPoint(x: 13, y: 40), tolerancePx: 12),       // generic
            TextNeighbor(text: "Audio 21", offset: CGPoint(x: 0, y: 60), tolerancePx: 12),    // unique & present
        ]
        let runs: [(text: String, box: CGRect)] = [
            ("wave", CGRect(x: 213, y: 140, width: 30, height: 12)),
            ("wave", CGRect(x: 213, y: 260, width: 30, height: 12)),   // generic repeats
            ("Audio 21", CGRect(x: 200, y: 160, width: 70, height: 16)),  // unique → expected (200,160)
        ]
        XCTAssertTrue(TextConstellation.hasUniqueNeighborSupport(box: box, neighbors: neighbors,
                                                                offsetScale: 1, tolerancePadPx: 24, runs: runs))
    }

    func testLocateByNeighborsRequiresMinAgree() {
        // Only one of two neighbors is found → a single (possibly ambiguous) anchor must NOT mislocate.
        let neighbors = [
            TextNeighbor(text: "label", offset: CGPoint(x: -100, y: 0), tolerancePx: 8),
            TextNeighbor(text: "other", offset: CGPoint(x: 0, y: 50), tolerancePx: 8),
        ]
        let runs: [(text: String, box: CGRect)] = [("label", CGRect(x: 100, y: 100, width: 40, height: 16))]
        XCTAssertNil(TextConstellation.locateByNeighbors(
            neighbors: neighbors, offsetScale: 1, tolerancePadPx: 6,
            elementSizePx: CGSize(width: 40, height: 16), minAgree: 2, runs: runs))
    }
}

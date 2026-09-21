import XCTest
import CoreGraphics
@testable import CVBackend

final class SobelPerceptualHasherTests: XCTestCase {
    let hasher = SobelPerceptualHasher()

    private func shapesA(px: Int = 128) -> CGImage {
        let s = CGFloat(px) / 128
        return patternImage(width: px, height: px, bg: 1.0, rects: [
            (CGRect(x: 20 * s, y: 20 * s, width: 40 * s, height: 30 * s), 0.0),
            (CGRect(x: 80 * s, y: 70 * s, width: 30 * s, height: 40 * s), 0.2),
        ])
    }

    /// Same geometry, colors inverted — edges are at the same places, so the edge map is unchanged.
    private func shapesAInverted() -> CGImage {
        patternImage(width: 128, height: 128, bg: 0.0, rects: [
            (CGRect(x: 20, y: 20, width: 40, height: 30), 1.0),
            (CGRect(x: 80, y: 70, width: 30, height: 40), 0.8),
        ])
    }

    private func shapesC() -> CGImage {
        patternImage(width: 128, height: 128, bg: 1.0, rects: [
            (CGRect(x: 5, y: 90, width: 60, height: 20), 0.0),
            (CGRect(x: 100, y: 10, width: 15, height: 100), 0.3),
        ])
    }

    func testHashLengthAndIdenticalDistanceZero() {
        let h = hasher.edgeHash(of: shapesA())
        XCTAssertEqual(h.count, 256)                 // 1024 bits / 4 = 256 hex chars
        XCTAssertEqual(hasher.distance(h, h), 0)
    }

    func testInvertedColorsStayClose() {
        let d = hasher.distance(hasher.edgeHash(of: shapesA()), hasher.edgeHash(of: shapesAInverted()))
        XCTAssertLessThanOrEqual(d, 10, "edge hash should be invariant to color inversion")
    }

    func testDifferentStructureIsFar() {
        let d = hasher.distance(hasher.edgeHash(of: shapesA()), hasher.edgeHash(of: shapesC()))
        XCTAssertGreaterThan(d, 10)
    }

    func testUnequalLengthIsIncomparable() {
        XCTAssertEqual(hasher.distance("ab", "abc"), Int.max)
    }

    func testHashIsMoreStableAcrossResolutionThanStructure() {
        // Same shapes at 2× resolution should move the hash LESS than a structural change does
        // (validates the area-downsample / resolution-stability fix, no magic threshold).
        let dResolution = hasher.distance(hasher.edgeHash(of: shapesA(px: 128)), hasher.edgeHash(of: shapesA(px: 256)))
        let dStructure = hasher.distance(hasher.edgeHash(of: shapesA(px: 128)), hasher.edgeHash(of: shapesC()))
        XCTAssertLessThan(dResolution, dStructure)
    }
}

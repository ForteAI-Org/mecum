import XCTest
import CoreGraphics
@testable import CVBackend

final class NCCTemplateMatcherTests: XCTestCase {
    let matcher = NCCTemplateMatcher()

    private func sampleImage() -> CGImage {
        patternImage(width: 64, height: 64, bg: 1.0, rects: [
            (CGRect(x: 10, y: 10, width: 8, height: 8), 0.2),
            (CGRect(x: 24, y: 18, width: 6, height: 6), 0.0),   // unique marker inside the crop
            (CGRect(x: 40, y: 30, width: 10, height: 8), 0.5),
            (CGRect(x: 5, y: 40, width: 12, height: 6), 0.7),
        ])
    }

    func testSelfCropScoresOneAtLocation() throws {
        let img = sampleImage()
        let crop = try XCTUnwrap(img.cropping(to: CGRect(x: 20, y: 16, width: 16, height: 12)))
        let m = try XCTUnwrap(matcher.match(template: crop, in: img, searchRegion: nil, scales: [1.0]))
        XCTAssertGreaterThan(m.score, 0.99)
        XCTAssertEqual(m.locationPx, CGPoint(x: 20, y: 16))
    }

    func testRespectsSearchRegion() throws {
        let img = sampleImage()
        let crop = try XCTUnwrap(img.cropping(to: CGRect(x: 20, y: 16, width: 16, height: 12)))

        let near = try XCTUnwrap(matcher.match(template: crop, in: img,
                                               searchRegion: CGRect(x: 14, y: 12, width: 24, height: 22), scales: [1.0]))
        XCTAssertEqual(near.locationPx, CGPoint(x: 20, y: 16))
        XCTAssertGreaterThan(near.score, 0.99)

        let far = try XCTUnwrap(matcher.match(template: crop, in: img,
                                              searchRegion: CGRect(x: 0, y: 0, width: 16, height: 14), scales: [1.0]))
        XCTAssertNotEqual(far.locationPx, CGPoint(x: 20, y: 16))
        XCTAssertLessThanOrEqual(far.locationPx.x, 15)   // constrained to the region's top-left positions
    }

    func testAbsentTemplateScoresBelowThreshold() throws {
        let img = sampleImage()
        let foreign = try XCTUnwrap(checkerboard(width: 64, height: 64, cell: 4).cropping(to: CGRect(x: 0, y: 0, width: 24, height: 24)))
        let m = try XCTUnwrap(matcher.match(template: foreign, in: img, searchRegion: nil, scales: [1.0]))
        XCTAssertLessThan(m.score, 0.85)
    }

    func testSmallTemplateNotCrushedByWindowDownscale() throws {
        // A small distinctive marker in a large window. maxSearchDimension would shrink the 800px window
        // ~4×; the template floor must keep the (24px) template usable so it still localizes here, rather
        // than collapsing to a few px that correlate ~1.0 with a flat patch at a garbage location.
        let img = patternImage(width: 800, height: 600, bg: 1.0, rects: [
            (CGRect(x: 600, y: 400, width: 10, height: 8), 0.0),
            (CGRect(x: 612, y: 405, width: 5, height: 5), 0.5),   // unique sub-marker
        ])
        let crop = try XCTUnwrap(img.cropping(to: CGRect(x: 596, y: 396, width: 24, height: 20)))
        let m = try XCTUnwrap(matcher.match(template: crop, in: img, searchRegion: nil, scales: [1.0],
                                            maxTemplateDimension: 128, maxSearchDimension: 200))
        XCTAssertGreaterThan(m.score, 0.9)
        XCTAssertEqual(m.locationPx.x, 596, accuracy: 8)
        XCTAssertEqual(m.locationPx.y, 396, accuracy: 8)
    }

    func testNearFlatRegionDoesNotSpuriouslyMatch() throws {
        // The avatar bug: a near-flat low-contrast background must NOT clamp to a spurious perfect NCC
        // and outscore the real textured element. Faint gradient (near-flat, tiny std-dev) + one
        // high-contrast marker; the textured template must localize on the MARKER, not a flat patch.
        let w = 160, h = 160
        let img = makeCGImage(width: w, height: h) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            for x in 0..<w {   // gray creeps 0.10 → 0.12 across the width — std-dev far below any UI element
                ctx.setFillColor(gray: 0.10 + 0.02 * CGFloat(x) / CGFloat(w), alpha: 1)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
            }
            ctx.setFillColor(gray: 1.0, alpha: 1); ctx.fill(CGRect(x: 110, y: 110, width: 18, height: 18))
            ctx.setFillColor(gray: 0.0, alpha: 1); ctx.fill(CGRect(x: 116, y: 116, width: 6, height: 6))
        }
        let crop = try XCTUnwrap(img.cropping(to: CGRect(x: 108, y: 108, width: 22, height: 22)))
        let m = try XCTUnwrap(matcher.match(template: crop, in: img, searchRegion: nil, scales: [1.0]))
        XCTAssertEqual(m.locationPx.x, 108, accuracy: 4)   // the marker, not a flat-gradient patch
        XCTAssertEqual(m.locationPx.y, 108, accuracy: 4)
        XCTAssertGreaterThan(m.score, 0.9)
    }

    func testTemplateLargerThanImageReturnsNil() {
        let img = sampleImage()
        let tooBig = patternImage(width: 100, height: 100, bg: 0.5, rects: [(CGRect(x: 10, y: 10, width: 20, height: 20), 0.0)])
        XCTAssertNil(matcher.match(template: tooBig, in: img, searchRegion: nil, scales: [1.0]))
    }
}

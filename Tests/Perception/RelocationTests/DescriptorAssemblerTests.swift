import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

final class DescriptorAssemblerTests: XCTestCase {
    let window = CGRect(x: 100, y: 50, width: 800, height: 600)

    func testWindowRelativeCenter() {
        // Element centered in the window → (0.5, 0.5). Center at global (500,350).
        let centered = CGRect(x: 500 - 12, y: 350 - 12, width: 24, height: 24)
        XCTAssertEqual(DescriptorAssembler.windowRelativeCenter(elementGlobalPt: centered, windowGlobalPt: window),
                       CGPoint(x: 0.5, y: 0.5))

        // Element at the window's top-left corner → center offset 12px each way.
        let corner = CGRect(x: 100, y: 50, width: 24, height: 24)
        let r = DescriptorAssembler.windowRelativeCenter(elementGlobalPt: corner, windowGlobalPt: window)
        XCTAssertEqual(r.x, 12.0 / 800, accuracy: 1e-9)
        XCTAssertEqual(r.y, 12.0 / 600, accuracy: 1e-9)
    }

    func testClickAnchoredRegionCentersOnClickAndStaysInWindow() {
        // A centered click → a centered box of the requested size.
        let centered = CGRect(x: 500 - 12, y: 350 - 12, width: 24, height: 24)   // center (500,350) in `window`
        let r = DescriptorAssembler.clickAnchoredRegionNorm(elementGlobalPt: centered, windowGlobalPt: window)
        XCTAssertEqual(r.midX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.midY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.height, 0.6, accuracy: 1e-9)

        // A near-corner click → the box is clamped fully inside [0,1] (origin pinned, size preserved) and
        // still CONTAINS the click point, so the wheel-delivery clamp lands on the actual click.
        let corner = CGRect(x: 100, y: 50, width: 24, height: 24)               // top-left of `window`
        let c = DescriptorAssembler.clickAnchoredRegionNorm(elementGlobalPt: corner, windowGlobalPt: window)
        XCTAssertEqual(c.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(c.minY, 0, accuracy: 1e-9)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(c))
        let click = DescriptorAssembler.windowRelativeCenter(elementGlobalPt: corner, windowGlobalPt: window)
        XCTAssertTrue(c.contains(click), "region must contain the click it is anchored on")
    }

    func testWindowRelativeClampsToUnitRange() {
        let g = DescriptorAssembler.geometry(elementGlobalPt: CGRect(x: 380, y: 280, width: 40, height: 40),
                                             windowGlobalPt: CGRect(x: 0, y: 0, width: 800, height: 600), backingScale: 2)
        XCTAssertTrue((0...1).contains(g.windowRelative.x))
        XCTAssertTrue((0...1).contains(g.windowRelative.y))
    }

    func testSizePxScalesByBackingScale() {
        XCTAssertEqual(DescriptorAssembler.sizePx(elementGlobalPt: CGRect(x: 0, y: 0, width: 24, height: 16), backingScale: 2),
                       CGSize(width: 48, height: 32))
    }

    func testExpectedRectReconstructsCenterAndSizeWhenUnchanged() {
        let w = CGRect(x: 0, y: 0, width: 800, height: 600)
        let e = CGRect(x: 380, y: 280, width: 40, height: 40)   // center (400,300)
        let g = DescriptorAssembler.geometry(elementGlobalPt: e, windowGlobalPt: w, backingScale: 1)
        let expected = DescriptorAssembler.expectedRectImagePx(
            geometry: g, captureWindowPixelSize: CGSize(width: 800, height: 600),
            currentWindowPixelSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(expected.midX, 400, accuracy: 1e-6)
        XCTAssertEqual(expected.midY, 300, accuracy: 1e-6)
        XCTAssertEqual(expected.width, 40, accuracy: 1e-6)
    }

    func testExpectedRectRescalesSizeWhenWindowPixelsChange() {
        // Capture at 800×600px; now the window's pixel size is halved (resize or 2×→1× DPI).
        let w = CGRect(x: 0, y: 0, width: 800, height: 600)
        let e = CGRect(x: 380, y: 280, width: 40, height: 40)
        let g = DescriptorAssembler.geometry(elementGlobalPt: e, windowGlobalPt: w, backingScale: 1)  // sizePx 40
        let expected = DescriptorAssembler.expectedRectImagePx(
            geometry: g, captureWindowPixelSize: CGSize(width: 800, height: 600),
            currentWindowPixelSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(expected.midX, 200, accuracy: 1e-6)   // center scales with the window
        XCTAssertEqual(expected.midY, 150, accuracy: 1e-6)
        XCTAssertEqual(expected.width, 20, accuracy: 1e-6)   // and so does the size (40 × 0.5)
        XCTAssertEqual(expected.height, 20, accuracy: 1e-6)
    }

    func testHealedUpdatesGeometryVersionAndTimestamp() {
        let d = makeDescriptor()   // windowRelative (0.5, 0.5), version 1
        let now = Date(timeIntervalSince1970: 1_700_009_999)
        let found = CGRect(x: 0, y: 0, width: 100, height: 60)   // center (50, 30)
        let healed = DescriptorAssembler.healed(d, foundRectPx: found, currentWindowPx: CGSize(width: 200, height: 120), now: now)

        XCTAssertEqual(healed.geometry.windowRelative, CGPoint(x: 0.25, y: 0.25))   // 50/200, 30/120
        XCTAssertEqual(healed.version, d.version + 1)
        XCTAssertEqual(healed.lastVerified, now)
        XCTAssertEqual(healed.visual.cropRef, d.visual.cropRef)   // crops left intact (conservative)
    }

    func testAnchorPicksNearestCorner() {
        let w = CGRect(x: 0, y: 0, width: 800, height: 600)
        let bottomRight = DescriptorAssembler.anchor(elementGlobalPt: CGRect(x: 760, y: 560, width: 30, height: 30),
                                                     windowGlobalPt: w, backingScale: 1)
        XCTAssertEqual(bottomRight.container, "bottomRight")
        let topLeft = DescriptorAssembler.anchor(elementGlobalPt: CGRect(x: 5, y: 5, width: 30, height: 30),
                                                 windowGlobalPt: w, backingScale: 1)
        XCTAssertEqual(topLeft.container, "topLeft")
    }
}

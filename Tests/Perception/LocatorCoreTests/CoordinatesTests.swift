import XCTest
import CoreGraphics
@testable import LocatorCore

final class CoordinatesTests: XCTestCase {
    // Golden fixture: window origin (100,50)pt, Retina scale 2.0, captured image 800×600 px.
    let ctx = WindowCoordinateContext(
        axWindowOriginGlobalPt: CGPoint(x: 100, y: 50),
        backingScale: 2.0,
        imagePixelSize: CGSize(width: 800, height: 600)
    )

    func testAXGlobalToImagePxHandComputed() {
        // (150-100)*2 = 100 ; (100-50)*2 = 100
        XCTAssertEqual(ctx.axGlobalToImagePx(CGPoint(x: 150, y: 100)), CGPoint(x: 100, y: 100))
    }

    func testAXImageRoundTrip() {
        let px = ctx.axGlobalToImagePx(CGPoint(x: 150, y: 100))
        XCTAssertEqual(ctx.imagePxToAXGlobal(px), CGPoint(x: 150, y: 100))
    }

    func testVisionNormToImagePxFlipsY() {
        // box (minX 0.25, minY 0.5, w 0.25, h 0.25) → maxY 0.75 → y = (1-0.75)*600 = 150
        let box = CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25)
        XCTAssertEqual(ctx.visionNormToImagePx(box), CGRect(x: 200, y: 150, width: 200, height: 150))
    }

    func testRectConversionRoundTrip() {
        let axRect = CGRect(x: 150, y: 100, width: 40, height: 20)
        let px = ctx.axGlobalToImagePx(axRect)
        XCTAssertEqual(px, CGRect(x: 100, y: 100, width: 80, height: 40))
        XCTAssertEqual(ctx.imagePxToAXGlobal(px), axRect)
    }

    func testCocoaScreenFlip() {
        // global height 900: AX top-left (10, 100) → Cocoa bottom-left (10, 800)
        XCTAssertEqual(axGlobalToCocoaScreen(CGPoint(x: 10, y: 100), globalHeightPt: 900), CGPoint(x: 10, y: 800))
    }
}

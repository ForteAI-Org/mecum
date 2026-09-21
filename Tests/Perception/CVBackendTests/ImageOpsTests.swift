import XCTest
import CoreGraphics
@testable import CVBackend

final class ImageOpsTests: XCTestCase {
    func testEqualLuminanceColorsStillHaveAnEdge() {
        let img = makeCGImage(width: 100, height: 100) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 200.0/255, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 102.0/255, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        }
        XCTAssertLessThan(ImageOps.sobelMagnitude(ImageOps.grayscale(img)).pixels.max()!, 5)
        XCTAssertGreaterThan(ImageOps.colorSobelMagnitude(img).pixels.max()!, 700)
        XCTAssertGreaterThan(ImageOps.colorSobelMagnitude(img, downsampleBy: 2).pixels.max()!, 700)
    }

    func testColorGradientMatchesNeutralGradient() {
        let img = makeCGImage(width: 100, height: 100) { ctx in
            ctx.setFillColor(gray: 0.2, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            ctx.setFillColor(gray: 0.8, alpha: 1); ctx.fill(CGRect(x: 30, y: 30, width: 40, height: 40))
        }
        let old = ImageOps.sobelMagnitude(ImageOps.grayscale(img)).pixels
        let color = ImageOps.colorSobelMagnitude(img).pixels
        for (a, b) in zip(old, color) { XCTAssertEqual(a, b, accuracy: 0.001) }
    }

    func testBilinearResizeDoesNotExtrapolate() {
        // Upscaling must interpolate within the source range, never overshoot (the LOW-2 fix).
        let src = GrayImage(width: 2, height: 2, pixels: [0, 100, 100, 0])
        let up = ImageOps.resize(src, to: 8, 8)
        XCTAssertGreaterThanOrEqual(up.pixels.min()!, 0)
        XCTAssertLessThanOrEqual(up.pixels.max()!, 100)
    }

    func testAreaDownsampleAverages() {
        // 4×4, left two columns 0, right two columns 100 → 2×2 averages to 0 | 100.
        let px: [Float] = (0..<16).map { ($0 % 4) < 2 ? 0 : 100 }
        let small = ImageOps.areaDownsample(GrayImage(width: 4, height: 4, pixels: px), to: 2, 2)
        XCTAssertEqual(small.pixels[0], 0, accuracy: 1e-3)
        XCTAssertEqual(small.pixels[1], 100, accuracy: 1e-3)
    }
}

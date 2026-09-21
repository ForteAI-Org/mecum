import XCTest
import CoreGraphics
@testable import CVBackend

final class ImageOpsTests: XCTestCase {
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

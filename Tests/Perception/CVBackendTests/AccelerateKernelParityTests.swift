import XCTest
import CoreGraphics
@testable import CVBackend

/// The Accelerate-backed kernels must equal the plain-Swift references BIT FOR BIT: a one-ulp drift
/// drifts every gradient that feeds the hashes and template matches (measured 2026-09-06:
/// 259/378/735 → 257/377/734 from a convolution routine summing in its own order).
final class AccelerateKernelParityTests: XCTestCase {
    private func noiseImage(w: Int, h: Int, seed: UInt64) -> CGImage {
        var state = seed
        func next() -> UInt8 { state = state &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: state >> 33) }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { bytes[i * 4] = next(); bytes[i * 4 + 1] = next(); bytes[i * 4 + 2] = next() }
        // a few flat runs so the mask has structure, not only noise
        for i in stride(from: 0, to: w * h, by: 7) { bytes[i * 4] = 40; bytes[i * 4 + 1] = 40; bytes[i * 4 + 2] = 40 }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testGrayscaleMatchesReference() {
        for (w, h, seed) in [(64, 48, 1), (301, 77, 2), (5, 5, 3)] as [(Int, Int, UInt64)] {
            let img = noiseImage(w: w, h: h, seed: seed)
            XCTAssertEqual(ImageOps.grayscale(img).pixels, ImageOps.referenceGrayscale(img).pixels, "grayscale \(w)×\(h)")
        }
    }

    func testSobelMatchesReference() {
        for (w, h, seed) in [(64, 48, 4), (301, 77, 5), (3, 3, 6), (9, 200, 7)] as [(Int, Int, UInt64)] {
            let g = ImageOps.referenceGrayscale(noiseImage(w: w, h: h, seed: seed))
            XCTAssertEqual(ImageOps.sobelMagnitude(g).pixels, ImageOps.referenceSobelMagnitude(g).pixels, "sobel \(w)×\(h)")
        }
    }

}

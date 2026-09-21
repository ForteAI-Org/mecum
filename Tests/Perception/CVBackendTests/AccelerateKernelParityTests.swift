import XCTest
import CoreGraphics
@testable import CVBackend

/// The Accelerate-backed kernels must equal the plain-Swift references BIT FOR BIT: a one-ulp drift
/// flips pixels sitting on the binarize threshold and moves benchmark boxes (measured 2026-09-06:
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

    private func noiseMask(w: Int, h: Int, seed: UInt64, density: Int) -> [Bool] {
        var state = seed
        return (0..<(w * h)).map { _ in state = state &* 6364136223846793005 &+ 1442695040888963407; return (state >> 40) % 100 < UInt64(density) }
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

    func testDilateAndErodeMatchReference() {
        for (w, h, r, d) in [(64, 48, 2, 10), (37, 91, 1, 30), (120, 7, 3, 50), (6, 6, 2, 60)] {
            let m = noiseMask(w: w, h: h, seed: UInt64(w * h + r), density: d)
            XCTAssertEqual(ImageOps.dilate(m, width: w, height: h, radius: r), ImageOps.referenceDilate(m, width: w, height: h, radius: r), "dilate \(w)×\(h) r\(r)")
            XCTAssertEqual(ImageOps.erode(m, width: w, height: h, radius: r), ImageOps.referenceErode(m, width: w, height: h, radius: r), "erode \(w)×\(h) r\(r)")
        }
    }

    func testColorSobelUsesTheVectorPathOnRealSizes() {
        // Integer-exact by construction; this guards the border and shape contract.
        let img = noiseImage(w: 50, h: 40, seed: 9)
        let g = ImageOps.colorSobelMagnitude(img)
        XCTAssertEqual(g.width, 50); XCTAssertEqual(g.height, 40)
        XCTAssertEqual(g.pixels[0], 0); XCTAssertEqual(g.pixels[49], 0); XCTAssertEqual(g.pixels[39 * 50 + 25], 0)
        XCTAssertGreaterThan(g.pixels[20 * 50 + 25], 0)
    }

    func testFrameHashIsStableAndSensitive() {
        let a = noiseImage(w: 64, h: 48, seed: 11), b = noiseImage(w: 64, h: 48, seed: 11), c = noiseImage(w: 64, h: 48, seed: 12)
        XCTAssertEqual(ImageOps.frameHash(a), ImageOps.frameHash(b), "same pixels → same hash")
        XCTAssertNotEqual(ImageOps.frameHash(a), ImageOps.frameHash(c), "different pixels → different hash")
        XCTAssertNotEqual(ImageOps.frameHash(a), ImageOps.frameHash(noiseImage(w: 48, h: 64, seed: 11)), "shape is part of identity")
    }
}

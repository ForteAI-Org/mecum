import XCTest
import CoreGraphics
@testable import CVBackend

final class ImageSurfaceDetectorTests: XCTestCase {
    private func scene(photo: Bool, gutter: Bool = false, overlay: Bool = false) -> CGImage {
        let w = 600, h = 400
        var bytes = [UInt8](repeating: 30, count: w * h * 4)
        var seed: UInt64 = 88172645463325252
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            if x >= 240 && x < 560 && y >= 40 && y < 220 {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                bytes[i] = photo ? UInt8(40 + (x + y + Int(seed & 63)) % 170) : 40
                bytes[i + 1] = photo ? UInt8(30 + (2 * x + Int(seed & 127)) % 190) : 110
                bytes[i + 2] = photo ? UInt8(20 + (3 * y + Int(seed & 63)) % 200) : 200
            }
            if gutter, x >= 398, x < 403, y >= 50, y < 220 {
                bytes[i] = 30; bytes[i + 1] = 30; bytes[i + 2] = 30
            }
            if overlay, x >= 350, x < 400, y >= 90, y < 145 {
                let v: UInt8 = x >= 372 && x < 378 && y >= 110 && y < 128 ? 240 : 30
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
            // Dense grayscale UI marks beside/below the image, plus a flat blue button.
            if (x < 200 || y > 250), x % 20 < 10, y % 16 < 5 {
                bytes[i] = 190; bytes[i + 1] = 190; bytes[i + 2] = 190
            }
            bytes[i + 3] = 255
        } }
        return CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func testPhotoIsOneSurfaceWithoutNeighboringUI() {
        let regions = ImageSurfaceDetector.detect(in: scene(photo: true))
        XCTAssertEqual(regions.count, 1)
        guard let region = regions.first else { return }
        XCTAssertTrue(region.contains(CGPoint(x: 400, y: 130)))
        XCTAssertGreaterThan(region.minX, 225)
        XCTAssertLessThan(region.maxY, 235)
    }

    func testFlatColorPanelAndDenseTextAreNotPhotographs() {
        XCTAssertTrue(ImageSurfaceDetector.detect(in: scene(photo: false)).isEmpty)
    }

    func testTextHeavySurfaceIsProtected() {
        let text = [CGRect(x: 245, y: 45, width: 300, height: 100)]
        XCTAssertTrue(ImageSurfaceDetector.detect(in: scene(photo: true), textBoxes: text).isEmpty)
    }

    func testAdjacentPhotosStaySeparateAndOverlappingPartsMerge() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 105, y: 0, width: 100, height: 100)
        XCTAssertEqual(ImageSurfaceDetector.consolidate([a, b]), [a, b])
        let part = CGRect(x: 80, y: 0, width: 40, height: 100)
        XCTAssertEqual(ImageSurfaceDetector.consolidate([a, part]), [a.union(part)])
    }

    func testThumbnailGutterCutsAThinPixelBridge() {
        let regions = ImageSurfaceDetector.detect(in: scene(photo: true, gutter: true))
        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions.contains { $0.maxX <= 403 })
        XCTAssertTrue(regions.contains { $0.minX >= 398 })
    }

    func testFlatBackedOverlayGlyphSurvivesButPictureTextureDoesNot() {
        let box = CGRect(x: 365, y: 105, width: 20, height: 30)
        let region = CGRect(x: 240, y: 40, width: 320, height: 180)
        XCTAssertTrue(ImageSurfaceDetector.hasControlBacking(box, in: scene(photo: true, overlay: true), regions: [region]))
        XCTAssertFalse(ImageSurfaceDetector.hasControlBacking(box, in: scene(photo: true), regions: [region]))
    }

    func testOnlyMostlyContainedSegmentsAreSuppressed() {
        let photo = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(ImageSurfaceDetector.containsMost(of: CGRect(x: 20, y: 20, width: 10, height: 10), in: [photo]))
        XCTAssertFalse(ImageSurfaceDetector.containsMost(of: CGRect(x: 90, y: 90, width: 20, height: 20), in: [photo]))
        XCTAssertFalse(ImageSurfaceDetector.containsMost(of: CGRect(x: 200, y: 0, width: 10, height: 10), in: [photo]))
    }
}

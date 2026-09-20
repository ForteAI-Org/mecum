import CoreGraphics
import PerceptionCore
import Testing

@testable import PixelRegions

@Suite("Media region filtering")
struct MediaRegionFilterTests {
    private let photo = CGRect(x: 240, y: 40, width: 320, height: 180)
    private let iconBesidePhoto = CGRect(x: 100, y: 90, width: 20, height: 20)
    private let detailInPhoto = CGRect(x: 290, y: 90, width: 20, height: 20)
    private let backedGlyph = CGRect(x: 365, y: 105, width: 20, height: 30)

    @Test("Photographic details are suppressed while adjacent UI remains")
    func photoDoesNotSwallowAdjacentUI() throws {
        let image = try scene(photo: true)
        let result = try MediaRegionFilter().filter(
            [iconBesidePhoto, detailInPhoto],
            in: image,
            protecting: []
        )
        let region = try #require(result.images.first)
        #expect(result.images.count == 1)
        #expect(region.contains(CGPoint(x: 400, y: 130)))
        #expect(region.minX > 225)
        #expect(region.maxY < 235)
        #expect(result.icons == [iconBesidePhoto])
        #expect(result.overlays.isEmpty)
    }

    @Test("Flat color panels and dense UI marks are not photographic surfaces")
    func flatPanelsRemainAvailable() throws {
        let result = try MediaRegionFilter().filter(
            [iconBesidePhoto, detailInPhoto],
            in: scene(photo: false),
            protecting: []
        )
        #expect(result.images.isEmpty)
        #expect(result.icons == [iconBesidePhoto, detailInPhoto])
        #expect(result.overlays.isEmpty)
    }

    @Test("Text coverage protects a textured UI surface")
    func textHeavySurfaceIsProtected() throws {
        let result = try MediaRegionFilter().filter(
            [detailInPhoto],
            in: scene(photo: true),
            protecting: [CGRect(x: 245, y: 45, width: 300, height: 100)]
        )
        #expect(result.images.isEmpty)
        #expect(result.icons == [detailInPhoto])
    }

    @Test("A flat-backed glyph survives as an overlay rather than an ordinary icon")
    func overlayRemainsSeparate() throws {
        let result = try MediaRegionFilter().filter(
            [iconBesidePhoto, backedGlyph, detailInPhoto],
            in: scene(photo: true, overlay: true),
            protecting: []
        )
        #expect(result.images.count == 1)
        #expect(result.icons == [iconBesidePhoto])
        #expect(result.overlays == [backedGlyph])
    }

    @Test("Picture texture cannot pass as a flat-backed overlay")
    func textureIsNotAnOverlay() throws {
        let result = try MediaRegionFilter().filter(
            [backedGlyph],
            in: scene(photo: true),
            protecting: []
        )
        #expect(result.icons.isEmpty)
        #expect(result.overlays.isEmpty)
    }

    @Test("Palette gutters separate adjacent thumbnails despite a thin texture bridge")
    func thumbnailGutterSeparatesSurfaces() throws {
        let result = try MediaRegionFilter().filter(
            [],
            in: scene(photo: true, gutter: true),
            protecting: []
        )
        #expect(result.images.count == 2)
        #expect(result.images.contains { $0.maxX <= 403 })
        #expect(result.images.contains { $0.minX >= 398 })
    }

    @Test("Candidates crossing the image edge are preserved when less than 70 percent lies inside")
    func boundaryCandidatesRemainAvailable() throws {
        let edge = CGRect(x: 220, y: 80, width: 40, height: 40)
        let result = try MediaRegionFilter().filter(
            [edge],
            in: scene(photo: true),
            protecting: []
        )
        #expect(result.images.count == 1)
        #expect(result.icons == [edge])
    }

    private func scene(
        photo hasPhoto: Bool,
        gutter: Bool = false,
        overlay: Bool = false
    ) throws -> CGImage {
        let width = 600
        let height = 400
        var bytes = [UInt8](repeating: 30, count: width * height * 4)
        var seed: UInt64 = 88_172_645_463_325_252
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if photo.contains(CGPoint(x: x, y: y)) {
                    seed ^= seed << 13
                    seed ^= seed >> 7
                    seed ^= seed << 17
                    bytes[offset] = hasPhoto ? UInt8(40 + (x + y + Int(seed & 63)) % 170) : 40
                    bytes[offset + 1] = hasPhoto ? UInt8(30 + (2 * x + Int(seed & 127)) % 190) : 110
                    bytes[offset + 2] = hasPhoto ? UInt8(20 + (3 * y + Int(seed & 63)) % 200) : 200
                }
                if gutter, x >= 398, x < 403, y >= 50, y < 220 {
                    bytes[offset] = 30
                    bytes[offset + 1] = 30
                    bytes[offset + 2] = 30
                }
                if overlay, x >= 350, x < 400, y >= 90, y < 145 {
                    let value: UInt8 = x >= 372 && x < 378 && y >= 110 && y < 128 ? 240 : 30
                    bytes[offset] = value
                    bytes[offset + 1] = value
                    bytes[offset + 2] = value
                }
                if x < 200 || y > 250, x % 20 < 10, y % 16 < 5 {
                    bytes[offset] = 190
                    bytes[offset + 1] = 190
                    bytes[offset + 2] = 190
                }
                bytes[offset + 3] = 255
            }
        }
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
            return try #require(context.makeImage())
        }
    }
}

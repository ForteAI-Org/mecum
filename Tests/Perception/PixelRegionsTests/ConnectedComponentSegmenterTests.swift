import CoreFoundation
import CoreGraphics
import Foundation
@testable import PixelRegions
import Testing

@Suite("Local visual components")
struct ConnectedComponentSegmenterTests {
    @Test("a compact glyph produces its image-pixel geometry without accessibility")
    func glyphGeometry() throws {
        let image = try image(width: 120, height: 100, filled: [
            CGRect(x: 30, y: 40, width: 20, height: 20)
        ])
        let boxes = try ConnectedComponentSegmenter().segments(in: image)
        #expect(boxes == [CGRect(x: 27, y: 37, width: 26, height: 26)])
    }

    @Test("a blank frame does not invent candidates")
    func blankFrame() throws {
        let image = try image(width: 120, height: 100)
        #expect(try ConnectedComponentSegmenter().segments(in: image).isEmpty)
    }

    @Test("inputs smaller than the edge kernel are empty", arguments: [1, 2])
    func tinyInput(side: Int) throws {
        let image = try image(width: side, height: side)
        #expect(try ConnectedComponentSegmenter().segments(in: image).isEmpty)
    }

    @Test("an oversized border chain is discarded while attached glyphs are rescued")
    func borderRescue() throws {
        let image = try image(width: 200, height: 140, filled: [
            CGRect(x: 10, y: 10, width: 180, height: 1),
            CGRect(x: 10, y: 129, width: 180, height: 1),
            CGRect(x: 10, y: 10, width: 1, height: 120),
            CGRect(x: 189, y: 10, width: 1, height: 120),
            CGRect(x: 16, y: 50, width: 20, height: 20),
            CGRect(x: 100, y: 65, width: 20, height: 20)
        ])
        let boxes = try ConnectedComponentSegmenter().segments(in: image)
        #expect(boxes.count == 2)
        #expect(boxes.contains(CGRect(x: 15, y: 49, width: 22, height: 22)))
        #expect(boxes.contains(CGRect(x: 97, y: 62, width: 26, height: 26)))
    }

    @Test("candidate order follows deterministic component discovery")
    func deterministicOrder() throws {
        let image = try image(width: 220, height: 150, filled: [
            CGRect(x: 150, y: 20, width: 20, height: 20),
            CGRect(x: 30, y: 80, width: 20, height: 20),
            CGRect(x: 100, y: 80, width: 20, height: 20)
        ])
        let expected = [
            CGRect(x: 147, y: 17, width: 26, height: 26),
            CGRect(x: 27, y: 77, width: 26, height: 26),
            CGRect(x: 97, y: 77, width: 26, height: 26)
        ]
        for _ in 0..<4 {
            #expect(try ConnectedComponentSegmenter().segments(in: image) == expected)
        }
    }

    @Test("Accelerate Sobel retains scalar gradient rounding")
    func acceleratedEdges() throws {
        let capture = try image(width: 23, height: 17, filled: [
            CGRect(x: 4, y: 5, width: 8, height: 7),
            CGRect(x: 15, y: 2, width: 4, height: 12)
        ])
        let grayscale = try #require(ImageOps.grayscale(capture))
        let edges = ImageOps.sobelMagnitude(grayscale)
        let width = grayscale.width
        let height = grayscale.height
        var expected = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let pixels = grayscale.pixels
                let horizontal = (pixels[index - width + 1] + 2 * pixels[index + 1] + pixels[index + width + 1])
                    - (pixels[index - width - 1] + 2 * pixels[index - 1] + pixels[index + width - 1])
                let vertical = (pixels[index + width - 1] + 2 * pixels[index + width] + pixels[index + width + 1])
                    - (pixels[index - width - 1] + 2 * pixels[index - width] + pixels[index - width + 1])
                expected[index] = (horizontal * horizontal + vertical * vertical).squareRoot()
            }
        }
        #expect(edges.pixels == expected)
    }

    /// Builds literal top-left row-major pixels so geometry checks do not depend on drawing transforms.
    private func image(width: Int, height: Int, filled rectangles: [CGRect] = []) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let isFilled = rectangles.contains {
                    CGFloat(x) >= $0.minX && CGFloat(x) < $0.maxX
                        && CGFloat(y) >= $0.minY && CGFloat(y) < $0.maxY
                }
                let value: UInt8 = isFilled ? 230 : 30
                let index = (y * width + x) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
                pixels[index + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}

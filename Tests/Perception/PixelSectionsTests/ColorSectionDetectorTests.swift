import CoreGraphics
import PixelSections
import Testing

@Suite("Color panel boundaries")
struct ColorSectionDetectorTests {
    @Test("a colored playhead crossing a panel is not a new section")
    func playhead() throws {
        let capture = try image { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 420, y: 0, width: 2, height: 400))
        }
        #expect(try ColorSectionDetector().sections(in: capture).isEmpty)
    }

    @Test("a strong track separator inside a weaker repeated row pattern is not a panel")
    func varyingRowStrength() throws {
        let capture = try image { context in
            context.setFillColor(CGColor(gray: 0.02, alpha: 1))
            for y in stride(from: 50, to: 400, by: 50) {
                let width = y == 150 ? 600 : 510
                context.fill(CGRect(x: 0, y: y, width: width, height: 2))
            }
        }
        #expect(try ColorSectionDetector().sections(in: capture).isEmpty)
    }
    private func image(_ draw: (CGContext) -> Void) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 600, height: 400,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        draw(context)
        return try #require(context.makeImage())
    }

    @Test("different hues form sections even at similar luminance")
    func equalLuminance() throws {
        let capture = try image { context in
            context.setFillColor(CGColor(red: 0.6, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 400))
            context.setFillColor(CGColor(red: 0.2, green: 0.319, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 240, y: 0, width: 360, height: 400))
        }
        let sections = try ColorSectionDetector().sections(in: capture)
        #expect(sections.count == 2)
        #expect(sections.contains { abs($0.maxX - 240) < 2 })
    }

    @Test("uniform backgrounds have no invented structure")
    func uniform() throws {
        #expect(try ColorSectionDetector().sections(in: image { _ in }).isEmpty)
    }

    @Test("repeated channel strips are kept together")
    func repeatingColumns() throws {
        let capture = try image { context in
            context.setFillColor(CGColor(gray: 0.02, alpha: 1))
            for x in stride(from: 60, to: 600, by: 60) {
                context.fill(CGRect(x: x, y: 0, width: 2, height: 400))
            }
        }
        #expect(try ColorSectionDetector().sections(in: capture).isEmpty)
    }

    @Test("a short edge inside a picture cannot cut the surrounding panel")
    func interiorPictureEdge() throws {
        let capture = try image { context in
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(CGRect(x: 130, y: 90, width: 240, height: 180))
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(CGRect(x: 240, y: 90, width: 3, height: 180))
        }
        #expect(try ColorSectionDetector().sections(in: capture).isEmpty)
    }
}

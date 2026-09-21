import XCTest
import CoreGraphics
import CoreText
@testable import OCRSupport
import LocatorCore

final class OCREngineTests: XCTestCase {
    /// Render a word as black-on-white so Vision can read it (no TCC, no network).
    private func makeTextImage(_ s: String, width: Int, height: Int, fontSize: CGFloat) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let fg = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: fg] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs)!)
        ctx.textPosition = CGPoint(x: 40, y: CGFloat(height) / 2 - fontSize / 3)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    func testRecognizesRenderedTextAndConvertsBoxes() throws {
        let (w, h) = (600, 200)
        let image = makeTextImage("HELLO", width: w, height: h, fontSize: 90)
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: .zero, backingScale: 1,
                                          imagePixelSize: CGSize(width: w, height: h))

        let results = OCREngine().recognizeText(in: image, ctx: ctx)

        XCTAssertFalse(results.isEmpty, "OCR returned nothing")
        let recognized = results.map { $0.text.uppercased() }
        XCTAssertTrue(recognized.contains { $0.contains("HELLO") }, "expected HELLO, got \(recognized)")

        // Every box is in top-left image-pixel space, inside the image, with positive area.
        let imageRect = CGRect(x: 0, y: 0, width: w, height: h)
        for r in results {
            XCTAssertGreaterThan(r.boxImagePx.width, 0)
            XCTAssertGreaterThan(r.boxImagePx.height, 0)
            XCTAssertTrue(imageRect.insetBy(dx: -2, dy: -2).contains(r.boxImagePx), "box \(r.boxImagePx) escaped image \(imageRect)")
        }
    }

    func testEmptyImageYieldsNoText() {
        let image = makeTextImage("", width: 200, height: 80, fontSize: 40)  // blank white
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: .zero, backingScale: 1,
                                          imagePixelSize: CGSize(width: 200, height: 80))
        XCTAssertTrue(OCREngine().recognizeText(in: image, ctx: ctx).isEmpty)
    }
}

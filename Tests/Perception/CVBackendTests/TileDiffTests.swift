import XCTest
import CoreGraphics
@testable import CVBackend

final class TileDiffTests: XCTestCase {
    private func image(w: Int, h: Int, paint: (CGContext) -> Void = { _ in }) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        paint(ctx)
        return ctx.makeImage()!
    }

    func testIdenticalFramesHaveNoDirtyTiles() {
        let a = image(w: 300, h: 200), b = image(w: 300, h: 200)
        let ga = TileDiff.grid(a, tile: 128)!, gb = TileDiff.grid(b, tile: 128)!
        XCTAssertEqual(ga.cols, 3); XCTAssertEqual(ga.rows, 2)
        XCTAssertEqual(TileDiff.dirtyRects(from: ga, to: gb), [])
    }

    func testOnePixelChangeDirtiesExactlyItsTile() {
        let a = image(w: 300, h: 200)
        let b = image(w: 300, h: 200) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 200, y: 200 - 150 - 1, width: 1, height: 1))   // image px (200,150)
        }
        let dirty = TileDiff.dirtyRects(from: TileDiff.grid(a, tile: 128)!, to: TileDiff.grid(b, tile: 128)!)!
        XCTAssertEqual(dirty, [CGRect(x: 128, y: 128, width: 128, height: 72)], "tile (1,1), clipped to the frame")
    }

    func testDifferentGeometryIsNotComparable() {
        let ga = TileDiff.grid(image(w: 300, h: 200), tile: 128)!, gb = TileDiff.grid(image(w: 301, h: 200), tile: 128)!
        XCTAssertNil(TileDiff.dirtyRects(from: ga, to: gb))
        XCTAssertNil(TileDiff.dirtyRects(from: ga, to: TileDiff.grid(image(w: 300, h: 200), tile: 64)!))
    }

    func testCoalesceMergesTouchingRects() {
        let r = TileDiff.coalesce([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 0, width: 10, height: 10),
                                   CGRect(x: 50, y: 50, width: 5, height: 5)])
        XCTAssertEqual(r, [CGRect(x: 0, y: 0, width: 20, height: 10), CGRect(x: 50, y: 50, width: 5, height: 5)])
    }
}

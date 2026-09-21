import XCTest
import CoreGraphics
@testable import Relocation

/// The scrollbar-thumb finder, pinned with synthetic panes. Resolve's preset strip ignores wheel
/// events entirely, so DRAGGING the thumb is the only thing that works — which means finding it in
/// the pixels has to be reliable.
final class HorizontalScrollerTests: XCTestCase {
    /// A pane: dark everywhere, with a bright horizontal bar (the thumb) near the bottom, offset `x0`.
    func pane(w: Int, h: Int, thumbX0: Int, thumbW: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.setFillColor(gray: 0.12, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CG origin is bottom-left; the thumb sits a few px up from the bottom.
        ctx.setFillColor(gray: 0.62, alpha: 1)
        ctx.fill(CGRect(x: thumbX0, y: 4, width: thumbW, height: 6))
        return ctx.makeImage()!
    }

    func testFindsThumbNearBottom() {
        let img = pane(w: 400, h: 120, thumbX0: 30, thumbW: 120)
        let t = HorizontalScroller.findThumb(in: img)
        XCTAssertNotNil(t)
        // thumb center ≈ 30 + 60 = 90; allow slack for the median threshold.
        XCTAssertEqual(Double(t!.midX), 90, accuracy: 20)
        XCTAssertTrue(t!.maxY > 100, "thumb should be near the bottom of the crop (top-left coords)")
    }

    func testThumbPositionTracksOffset() {
        let left = HorizontalScroller.findThumb(in: pane(w: 400, h: 120, thumbX0: 20, thumbW: 100))!
        let right = HorizontalScroller.findThumb(in: pane(w: 400, h: 120, thumbX0: 240, thumbW: 100))!
        XCTAssertLessThan(left.midX, right.midX)   // a scrolled-right thumb reads further right
    }

    func testNoThumbWhenPaneIsUniform() {
        let ctx = CGContext(data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 300,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.setFillColor(gray: 0.2, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        XCTAssertNil(HorizontalScroller.findThumb(in: ctx.makeImage()!))   // nothing bright ⇒ not scrollable
    }

    func testFullWidthBarIsNotAThumb() {
        // A full-width bright band is a divider/background, not a thumb (len > 85% of width).
        XCTAssertNil(HorizontalScroller.findThumb(in: pane(w: 400, h: 120, thumbX0: 0, thumbW: 400)))
    }
}

/// WHICH WAY DID IT SLIDE — the pixel evidence that replaced a second full scene build in the
/// horizontal scroll verb. The wheel2 sign that reveals the right-hand side depends on the system's
/// natural-scroll setting (measured live: the assumed sign revealed the OPPOSITE side), so the verb
/// probes two ticks and MEASURES the slide before committing to the rest. Synthetic strips here:
/// aperiodic "cards" in a band, slid sideways inside unchanging chrome.
final class HorizontalSlideTests: XCTestCase {
    /// 800×300 strip: fixed chrome down the left edge, aperiodic content columns offset by `slide`.
    private func strip(slide: Int, noise: Bool = false) -> CGImage {
        let w = 800, h = 300
        var buf = [UInt8](repeating: 235, count: w * h)
        for y in 0..<h { for x in 0..<40 { buf[y * w + x] = 30 } }        // fixed chrome
        let cards: [(Int, Int, UInt8)] = [(0, 24, 10), (48, 60, 120), (130, 18, 60), (170, 44, 200),
                                          (240, 30, 35), (300, 52, 150), (380, 20, 80), (430, 36, 20),
                                          (500, 26, 175), (560, 48, 95)]
        for (start, width, shade) in cards {
            for dx in 0..<width {
                let x = 60 + start + dx + slide
                guard x >= 60, x < w else { continue }
                for y in 40..<260 { buf[y * w + x] = noise ? UInt8((x * 7 + y * 13) % 255) : shade }
            }
        }
        return buf.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                .makeImage()!
        }
    }

    func testContentSlidingRightReadsPositive() {
        // Content moved RIGHT ⇒ the view revealed what was on the LEFT ⇒ positive by convention.
        let px = HorizontalScroller.contentSlidePx(before: strip(slide: 0), after: strip(slide: 40))
        XCTAssertNotNil(px)
        XCTAssertGreaterThan(px ?? 0, 0, "content sliding right must read positive")
        // The units are DOWNSAMPLED columns (the profile is at most 512 wide), so a 40px slide of an
        // 800px strip reads 40 × 512/800 ≈ 26 — the documented contract, not window pixels.
        XCTAssertEqual(Double(px ?? 0), 40 * 512.0 / 800.0, accuracy: 6)
    }

    func testBiggerSlideReadsBigger() {
        let small = HorizontalScroller.contentSlidePx(before: strip(slide: 0), after: strip(slide: 30))
        let big = HorizontalScroller.contentSlidePx(before: strip(slide: 0), after: strip(slide: 90))
        XCTAssertGreaterThan(big ?? 0, small ?? 0)   // magnitude tracks the real slide
    }

    func testContentSlidingLeftReadsNegative() {
        let px = HorizontalScroller.contentSlidePx(before: strip(slide: 40), after: strip(slide: 0))
        XCTAssertNotNil(px)
        XCTAssertLessThan(px ?? 0, 0, "content sliding left (revealing the right side) must read negative")
    }

    func testStillStripReadsNoSlide() {
        XCTAssertNil(HorizontalScroller.contentSlidePx(before: strip(slide: 0), after: strip(slide: 0)))
    }

    func testIncoherentChangeIsNotASlide() {
        // The band changes but nothing slides — a repaint or an animation, not a scroll.
        XCTAssertNil(HorizontalScroller.contentSlidePx(before: strip(slide: 0),
                                                      after: strip(slide: 0, noise: true)))
    }
}

import XCTest
import CoreGraphics
@testable import CVBackend

/// Suppress ONLY textured + segment-heavy + roughly-square + TEXT-SPARSE-BY-AREA regions (photos);
/// leave UI. The text signal is COVERAGE (text pixel-area / region area) — resolution-invariant, unlike
/// the old runs-per-megapixel which broke at the live window size.
final class ContentRegionDetectorTests: XCTestCase {
    private func img(_ w: Int, _ h: Int, _ paint: (inout [UInt8], Int, Int) -> Void) -> CGImage {
        var rgba = [UInt8](repeating: 0, count: w*h*4); paint(&rgba, w, h)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    private func noise(_ w: Int, _ h: Int) -> CGImage {
        img(w, h) { px, w, h in
            var s: UInt64 = 88172645463325252
            func r() -> UInt8 { s ^= s<<13; s ^= s>>7; s ^= s<<17; return UInt8(s & 0xFF) }
            for i in 0..<(w*h) { px[i*4]=r(); px[i*4+1]=r(); px[i*4+2]=r(); px[i*4+3]=255 }
        }
    }
    /// `n` segment boxes of size `sz` scattered across `base` (deterministic).
    private func boxes(_ base: CGRect, _ n: Int, _ a: Int, _ b: Int, sz: Double = 6) -> [CGRect] {
        var out: [CGRect] = []
        for i in 0..<n {
            let x: Double = base.minX + Double((i * a) % max(1, Int(base.width)))
            let y: Double = base.minY + Double((i * b) % max(1, Int(base.height)))
            out.append(CGRect(x: x, y: y, width: sz, height: sz))
        }
        return out
    }
    /// Text boxes covering ~`fraction` of `base`, laid out as a grid of word-sized rects (word = wxh px).
    private func textCovering(_ base: CGRect, fraction: Double, wordW: Double, wordH: Double) -> [CGRect] {
        let target = Double(base.width * base.height) * fraction
        let per = wordW * wordH
        let count = max(1, Int((target / per).rounded()))
        var out: [CGRect] = []
        let cols = max(1, Int((base.width / (wordW + 4)).rounded(.down)))
        for i in 0..<count {
            let cx = i % cols, cy = i / cols
            out.append(CGRect(x: base.minX + Double(cx) * (wordW + 4),
                              y: base.minY + Double(cy) * (wordH + 4), width: wordW, height: wordH))
        }
        return out
    }

    func testSuppressesPhotoRegion() {   // many segs, ~no text → photo → suppress
        let r = ContentRegionDetector.contentRegions(in: noise(320, 320),
                    segments: boxes(CGRect(x: 20, y: 20, width: 280, height: 280), 40, 13, 17), textBoxes: [])
        XCTAssertFalse(r.isEmpty)
    }
    func testTextHeavyRegionKept() {   // same segs, but text covers ~40% of area → UI → kept
        let region = CGRect(x: 20, y: 20, width: 280, height: 280)
        let texts = textCovering(region, fraction: 0.40, wordW: 40, wordH: 14)
        let r = ContentRegionDetector.contentRegions(in: noise(320, 320),
                    segments: boxes(region, 40, 13, 17), textBoxes: texts)
        XCTAssertTrue(r.isEmpty)
    }
    func testStripKept() {   // extreme aspect (8:1) → UI bar, not a photo
        let r = ContentRegionDetector.contentRegions(in: noise(640, 80),
                    segments: boxes(CGRect(x: 0, y: 0, width: 640, height: 80), 60, 13, 7), textBoxes: [])
        XCTAssertTrue(r.isEmpty)
    }
    func testSparseKept() {   // too few segments → not the explosion
        let r = ContentRegionDetector.contentRegions(in: noise(320, 320),
                    segments: boxes(CGRect(x: 20, y: 20, width: 280, height: 280), 3, 13, 17), textBoxes: [])
        XCTAssertTrue(r.isEmpty)
    }

    /// Connected texture around toolbars/panel edges encloses a mostly flat UI. Its bounding box
    /// must not turn every control in that quiet interior into photographic content.
    func testSparseTextureFrameDoesNotSuppressItsQuietInterior() {
        for scale in [1, 2] {
            let w = 320 * scale, border = 40 * scale
            let framed = img(w, w) { px, w, h in
                var seed: UInt64 = 88172645463325252
                for y in 0..<h { for x in 0..<w {
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                    let edge = x < border || y < border || x >= w - border || y >= h - border
                    let value = edge ? UInt8(seed & 255) : UInt8(128)
                    let i = (y * w + x) * 4
                    px[i] = value; px[i+1] = value; px[i+2] = value; px[i+3] = 255
                } }
            }
            let r = ContentRegionDetector.contentRegions(in: framed,
                segments: boxes(CGRect(x: 20, y: 20, width: w-40, height: w-40), 60, 13, 17))
            XCTAssertTrue(r.isEmpty, "connected border texture must not suppress a quiet panel at scale \(scale)")
        }
    }

    /// A LEFT-ALIGNED COLUMN of text rows at LOW coverage is a navigation list (a tall note-list is mostly
    /// whitespace), NOT a photo — the measured Notes false-positive. It must be KEPT even under the
    /// coverage threshold, rescued by alignment.
    func testAlignedListKeptAtLowCoverage() {
        let region = CGRect(x: 20, y: 20, width: 280, height: 280)
        var texts: [CGRect] = []                                   // 16 rows, all sharing left x=30
        for i in 0..<16 { texts.append(CGRect(x: 30, y: 24 + Double(i) * 17, width: 40, height: 10)) }
        let cov = 16.0 * 40 * 10 / (280 * 280)                     // ~8% coverage — below the 15% gate
        XCTAssertLessThan(cov, 0.15)
        let r = ContentRegionDetector.contentRegions(in: noise(320, 320),
                    segments: boxes(region, 40, 13, 17), textBoxes: texts)
        XCTAssertTrue(r.isEmpty, "an aligned low-coverage text column is a list, not a photo")
    }

    /// Same low coverage but SCATTERED text (captions/numbers on an image) → a photo → suppressed.
    func testScatteredLowCoverageSuppressed() {
        let region = CGRect(x: 20, y: 20, width: 280, height: 280)
        var texts: [CGRect] = []                                   // 16 boxes scattered across x and y
        for i in 0..<16 { texts.append(CGRect(x: 30 + Double((i * 53) % 220), y: 24 + Double((i * 37) % 240), width: 40, height: 10)) }
        let r = ContentRegionDetector.contentRegions(in: noise(320, 320),
                    segments: boxes(region, 40, 13, 17), textBoxes: texts)
        XCTAssertFalse(r.isEmpty, "scattered low-coverage text is a photo → suppress")
    }

    /// THE REGRESSION GUARD: the SAME logical content at two resolutions must yield the SAME decision.
    /// Text boxes scale with the image, so coverage is identical; the old runs/Mpx signal would have
    /// differed 4× between these two scales (the measured "under-fires at 1840px" bug).
    func testCoverageIsResolutionInvariant() {
        for scale in [1.0, 2.0] {
            let W = Int(320 * scale), H = Int(320 * scale)
            let region = CGRect(x: 20 * scale, y: 20 * scale, width: 280 * scale, height: 280 * scale)
            // A PHOTO: many segments, text covering only ~5% → suppressed at BOTH scales.
            let photo = ContentRegionDetector.contentRegions(in: noise(W, H),
                segments: boxes(region, 40, 13, 17, sz: 6 * scale),
                textBoxes: textCovering(region, fraction: 0.05, wordW: 40 * scale, wordH: 14 * scale))
            XCTAssertFalse(photo.isEmpty, "photo should suppress at scale \(scale)")
            // A UI PANEL: same segments, text covering ~35% → kept at BOTH scales.
            let ui = ContentRegionDetector.contentRegions(in: noise(W, H),
                segments: boxes(region, 40, 13, 17, sz: 6 * scale),
                textBoxes: textCovering(region, fraction: 0.35, wordW: 40 * scale, wordH: 14 * scale))
            XCTAssertTrue(ui.isEmpty, "UI should be kept at scale \(scale)")
        }
    }
}

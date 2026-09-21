import XCTest
import CoreGraphics
import CoreText
@testable import OCRSupport
import LocatorCore

/// Reproduction probe for the Apple Vision native-memory leak screenpipe hit in production
/// (their v2.5.79: 19.6 GB RSS after weeks of always-on OCR ≈ 1 GB/day; their repro:
/// screenpipe-screen/src/apple.rs `repro_apple_ocr_leak`). VNRecognizeTextRequest is a known
/// source of CoreFoundation/MLModel buffer growth that autorelease draining does NOT reclaim.
/// Our `locator serve --watch` is exactly the exposed shape — Vision OCR in a loop, forever —
/// so we keep their probe alive on OUR stack.
///
/// Diagnostic, not correctness: a CLEAN path warms up (model load) then PLATEAUS; a LEAK climbs
/// roughly linearly with iterations. No hard assertion — read the printed curve. Gated off by
/// default so `swift test` stays fast:
///
///   LOCATOR_OCR_LEAK_REPRO=1 swift test --filter OCRLeakRepro 2>&1 | grep ocr-repro
///
/// Runs on an in-memory synthetic frame — no Screen Recording TCC, reproduces headless.
final class OCRLeakReproTests: XCTestCase {
    /// Peak resident set in bytes (ru_maxrss is BYTES on Darwin, unlike Linux's KB).
    private func peakRSSBytes() -> UInt64 {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return UInt64(ru.ru_maxrss)
    }

    /// A capture-shaped frame of dashed high-contrast bars — text-like enough that Vision engages
    /// its full pipeline. Content varies by seed so the OS can't short-circuit a repeated input.
    private func makeFrame(seed: Int, width: Int = 1280, height: Int = 800) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0.04, alpha: 1)
        for line in 0..<20 {
            let y0 = 20 + line * 38 + (seed % 7)
            let xEnd = 80 + ((line * 53 + seed) % (width - 160))
            var x = 60
            while x < xEnd {                       // dashes to mimic words/letters
                if (x / 9) % 2 == 0 { ctx.fill(CGRect(x: x, y: y0, width: 9, height: 16)) }
                x += 9
            }
        }
        return ctx.makeImage()!
    }

    func testAppleVisionOCRLeakCurve() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCATOR_OCR_LEAK_REPRO"] == "1",
                          "leak repro is opt-in: LOCATOR_OCR_LEAK_REPRO=1")
        let iterations = Int(ProcessInfo.processInfo.environment["LOCATOR_OCR_LEAK_ITERS"] ?? "") ?? 1500
        // Default probes `.fast` (the always-on cadence); LOCATOR_OCR_LEAK_ACCURATE=1 probes the
        // scene-build level instead.
        let accurate = ProcessInfo.processInfo.environment["LOCATOR_OCR_LEAK_ACCURATE"] == "1"
        let checkpoint = 125
        let engine = OCREngine()
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: .zero, backingScale: 1,
                                          imagePixelSize: CGSize(width: 1280, height: 800))
        let mb = { (b: UInt64) in Double(b) / 1_048_576.0 }
        let baseline = peakRSSBytes()
        print(String(format: "[ocr-repro] baseline peak RSS: %.1f MB", mb(baseline)))

        var last = baseline
        for i in 0..<iterations {
            let frame = makeFrame(seed: i)
            _ = engine.recognizeText(in: frame, ctx: ctx, accurate: accurate)
            if (i + 1) % checkpoint == 0 {
                let now = peakRSSBytes()
                print(String(format: "[ocr-repro] after %5d OCRs: peak RSS %.1f MB (+%.1f since last, +%.1f total)",
                             i + 1, mb(now), mb(now &- last), mb(now &- baseline)))
                last = now
            }
        }
        let total = peakRSSBytes() &- baseline
        print(String(format: "[ocr-repro] TOTAL peak-RSS growth over %d OCRs: %.1f MB (~%.2f KB/call)",
                     iterations, mb(total), Double(total) / 1024.0 / Double(iterations)))
    }
}

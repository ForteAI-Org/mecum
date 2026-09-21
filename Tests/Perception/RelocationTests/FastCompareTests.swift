import XCTest
import CoreGraphics
import CoreText
@testable import Relocation
import CVBackend
import LocatorCore
import OCRSupport

/// The FAST-VERIFICATION TIER (comparison-only perception) and — the point of the ticket — its SCOPE
/// GUARD: a full scene's element set must be byte-identical whether or not the fast tier is used, so the
/// speed knob provably cannot leak into anything the agent reads.
final class FastCompareTests: XCTestCase {

    /// Black-on-white rows so Vision reads them with no TCC and no network.
    private func makeRowsImage(width: Int, height: Int, rows: [(String, CGFloat)], fontSize: CGFloat = 34) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let fg = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: fg] as CFDictionary
        for (text, yTopPx) in rows {
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs)!)
            ctx.textPosition = CGPoint(x: 40, y: CGFloat(height) - yTopPx - fontSize)   // CG origin is bottom-left
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }

    private func makeBuilder() throws -> SceneBuilder {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fastcompare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SceneBuilder(icons: IconStore(directory: dir), knowledge: KnowledgeStore(directory: dir))
    }

    // MARK: - the tier itself

    /// Section scoping: only the labels INSIDE the given pane come back — a scroll check on the sidebar
    /// must not be fooled by the toolbar changing.
    func testLabelsAreScopedToTheSectionRect() {
        let img = makeRowsImage(width: 700, height: 800, rows: [("TOOLBAR", 40), ("ALPHA", 420), ("BRAVO", 520)])
        let bottomHalf = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)

        let scoped = SceneBuilder.compareLabels(in: img, sectionRectNorm: bottomHalf)

        XCTAssertTrue(scoped.contains("alpha"), "expected the in-section rows, got \(scoped)")
        XCTAssertTrue(scoped.contains("bravo"), "expected the in-section rows, got \(scoped)")
        XCTAssertFalse(scoped.contains("toolbar"), "out-of-section text leaked in: \(scoped)")
    }

    /// Whole frame when no section is given.
    func testNilSectionReadsTheWholeFrame() {
        let img = makeRowsImage(width: 700, height: 800, rows: [("TOOLBAR", 40), ("ALPHA", 420)])
        let all = SceneBuilder.compareLabels(in: img, sectionRectNorm: nil)
        XCTAssertTrue(all.contains("toolbar") && all.contains("alpha"), "expected the whole frame, got \(all)")
    }

    /// A moved list reads as a DIFFERENT set; an unchanged one as the same set. This is the only thing
    /// the tier is allowed to answer.
    func testSetComparisonSeesMovementAndStillness() {
        let before = makeRowsImage(width: 700, height: 800, rows: [("ALPHA", 200), ("BRAVO", 320), ("CHARLIE", 440)])
        let same = makeRowsImage(width: 700, height: 800, rows: [("ALPHA", 200), ("BRAVO", 320), ("CHARLIE", 440)])
        let after = makeRowsImage(width: 700, height: 800, rows: [("DELTA", 200), ("ECHO", 320), ("FOXTROT", 440)])

        let a = SceneBuilder.compareLabels(in: before, sectionRectNorm: nil)
        XCTAssertEqual(a, SceneBuilder.compareLabels(in: same, sectionRectNorm: nil), "identical pixels must give an identical set")
        XCTAssertNotEqual(a, SceneBuilder.compareLabels(in: after, sectionRectNorm: nil), "a scrolled list must give a different set")
    }

    /// Normalization: the same fold the scene diff uses (lowercased alphanumerics), so a fast sample and
    /// an accurate scene's labels are comparable key-for-key — and punctuation-only runs (fast-OCR's
    /// favourite junk) drop out, so a flickering stray tick can never be read as movement.
    func testLabelNormalizationMatchesTheSceneDiffFold() {
        XCTAssertEqual(SceneBuilder.compareKey("  Audio   6 "), KnowledgeText.normalize("Audio 6"))
        XCTAssertEqual(SceneBuilder.compareKey("MIX"), "mix")
        XCTAssertEqual(SceneBuilder.compareKey("v2"), "v2")
        XCTAssertNil(SceneBuilder.compareKey("  "))
        XCTAssertNil(SceneBuilder.compareKey("—"))
        XCTAssertNil(SceneBuilder.compareKey("·|·"))
    }

    // MARK: - the scope guard (the acceptance criterion)

    /// THE GUARD: a full scene's element set is byte-identical with the fast tier in the picture — before
    /// it runs, after it runs, and interleaved. If the knob ever leaked into the scene pipeline (a shared
    /// OCR mode, a poisoned cache), these bytes would move.
    func testFullSceneElementSetIsByteIdenticalAroundFastTierUse() throws {
        let builder = try makeBuilder()
        let img = makeRowsImage(width: 700, height: 800,
                                rows: [("TOOLBAR", 40), ("ALPHA", 220), ("BRAVO", 340), ("CHARLIE", 460), ("DELTA", 580)])
        let pixelSize = CGSize(width: img.width, height: img.height)
        func sceneBytes() throws -> Data {
            let elements = SceneBuilder.makeElements(builder.detect(in: img, appIcons: nil), pixelSize: pixelSize)
            return try DescriptorStore.makeEncoder().encode(elements)
        }

        let before = try sceneBytes()
        _ = SceneBuilder.compareLabels(in: img, sectionRectNorm: CGRect(x: 0, y: 0.2, width: 1, height: 0.6))
        let afterOnce = try sceneBytes()
        for _ in 0..<3 { _ = SceneBuilder.compareLabels(in: img, sectionRectNorm: nil) }
        let afterMany = try sceneBytes()

        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(before, afterOnce, "the fast tier perturbed the scene's element set")
        XCTAssertEqual(before, afterMany, "the fast tier perturbed the scene's element set")
    }

    /// A section rect that lands outside the frame (a stale scene's coordinates against a resized window)
    /// answers "nothing", never a crash and never the whole frame.
    func testOffFrameSectionYieldsNothing() {
        let img = makeRowsImage(width: 400, height: 300, rows: [("ALPHA", 100)])
        XCTAssertTrue(SceneBuilder.compareLabels(in: img, sectionRectNorm: CGRect(x: 2, y: 2, width: 0.5, height: 0.5)).isEmpty)
        XCTAssertTrue(SceneBuilder.compareLabels(in: img, sectionRectNorm: CGRect(x: 0, y: 0, width: 0.001, height: 0.001)).isEmpty)
    }
}

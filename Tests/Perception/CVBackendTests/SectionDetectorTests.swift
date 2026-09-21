import XCTest
import CoreGraphics
@testable import CVBackend

final class SectionDetectorTests: XCTestCase {
    func testColumnsStopBelowSharedToolbar() {
        let img = panels(width: 1000, height: 800, fills: [
            (CGRect(x: 0, y: 0, width: 1000, height: 50), 0.1),
            (CGRect(x: 0, y: 52, width: 300, height: 748), 0.2),
            (CGRect(x: 302, y: 52, width: 698, height: 748), 0.8)
        ])
        let sections = SectionDetector.detect(in: img)
        XCTAssertTrue(sections.contains { $0.width == 1000 && $0.minY == 0 && $0.maxY < 60 })
        XCTAssertFalse(sections.contains { $0.minX > 0 && $0.minY < 45 })
    }

    func testFieldBorderIsNotASectionBoundary() {
        let img = panels(width: 1000, height: 800, fills: [
            (CGRect(x: 250, y: 100, width: 650, height: 40), 0.1)
        ])
        XCTAssertEqual(SectionDetector.detect(in: img).count, 1)
    }

    func testRepeatedAccordionRowsKeepTheirStartAndOtherSeams() {
        let lines = ([40, 170] + Array(stride(from: 300, through: 900, by: 50)) + [1100])
            .map { (pos: $0, fill: 1.0) }
        XCTAssertEqual(SectionDetector.collapseRepeatedRows(lines).map(\.pos), [40, 170, 300, 1100])
    }

    func testColorOnlyPanelBoundarySurvives() {
        let img = makeCGImage(width: 1000, height: 800) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 200.0/255, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 102.0/255, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 300, y: 0, width: 700, height: 800))
        }
        var gray = SectionDetector.Params(); gray.useColorEdges = false
        XCTAssertEqual(SectionDetector.detect(in: img, params: gray).count, 1)
        XCTAssertEqual(SectionDetector.detect(in: img).count, 2)
    }

    /// Paint filled panels separated by 1px dark gutters on a mid-gray window → hard edges at the seams.
    private func panels(width: Int, height: Int, fills: [(CGRect, CGFloat)]) -> CGImage {
        makeCGImage(width: width, height: height) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (r, g) in fills { ctx.setFillColor(gray: g, alpha: 1); ctx.fill(r) }
        }
    }

    func testVerticalSplitFindsTwoColumns() {
        // A dark sidebar column (0..300) beside a light content column (302..1000).
        let img = panels(width: 1000, height: 800, fills: [
            (CGRect(x: 0, y: 0, width: 300, height: 800), 0.15),
            (CGRect(x: 302, y: 0, width: 698, height: 800), 0.85),
        ])
        let s = SectionDetector.detect(in: img)
        XCTAssertGreaterThanOrEqual(s.count, 2)
        // a boundary near x≈300 (the seam) — some section starts there
        XCTAssertTrue(s.contains { abs($0.minX - 300) < 40 || abs($0.maxX - 300) < 40 })
    }

    func testHorizontalStripSplit() {
        // A top toolbar strip over a body.
        let img = panels(width: 1000, height: 800, fills: [
            (CGRect(x: 0, y: 0, width: 1000, height: 90), 0.2),
            (CGRect(x: 0, y: 92, width: 1000, height: 708), 0.8),
        ])
        let s = SectionDetector.detect(in: img)
        XCTAssertTrue(s.contains { abs($0.maxY - 90) < 40 || abs($0.minY - 90) < 40 })
    }

    func testUniformImageIsOneSection() {   // no boundaries → the whole window is one section, never crash
        let flat = makeCGImage(width: 800, height: 600) { ctx in
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let s = SectionDetector.detect(in: flat)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0], CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testRepeatedTextStrokesAreNotVerticalPanels() {
        // 75% edge fill, but separated into short rows like the TextEdit document's aligned glyphs.
        var fills: [(CGRect, CGFloat)] = []
        for x in [100, 180, 260] {
            for y in stride(from: 0, to: 800, by: 32) {
                fills.append((CGRect(x: x, y: y, width: 3, height: 24), 0.1))
            }
        }
        let image = panels(width: 1000, height: 800, fills: fills)
        XCTAssertEqual(SectionDetector.detect(in: image).count, 1)
    }

    func testInterruptedButSustainedDividerSurvives() {
        let image = panels(width: 1000, height: 800, fills: [
            (CGRect(x: 300, y: 0, width: 3, height: 330), 0.1),
            (CGRect(x: 300, y: 400, width: 3, height: 330), 0.1)
        ])
        XCTAssertGreaterThanOrEqual(SectionDetector.detect(in: image).count, 2)
    }

    func testDownsampleRemainderStillCoversWholeWindow() {
        let image = panels(width: 2003, height: 1603, fills: [])
        let sections = SectionDetector.detect(in: image)
        XCTAssertEqual(sections.count, 1)
        guard let section = sections.first else { return }
        XCTAssertEqual(section.minX, 0, accuracy: 0.000001)
        XCTAssertEqual(section.minY, 0, accuracy: 0.000001)
        XCTAssertEqual(section.maxX, 2003, accuracy: 0.000001)
        XCTAssertEqual(section.maxY, 1603, accuracy: 0.000001)
    }

    func testPeriodicGridIsNotOverCut() {
        // 12 evenly-spaced thin dark dividers = a toolbar of cells, NOT 12 panels → stays ~one section.
        var fills: [(CGRect, CGFloat)] = [(CGRect(x: 0, y: 0, width: 1000, height: 800), 0.6)]
        for i in 1..<12 { fills.append((CGRect(x: i * 80, y: 0, width: 2, height: 800), 0.1)) }
        let s = SectionDetector.detect(in: panels(width: 1000, height: 800, fills: fills))
        XCTAssertLessThanOrEqual(s.count, 3)   // periodicity veto: not 12 slivers
    }

    func testSectionsCoverAndDoNotOverlap() {   // X-Y cut is a partition — leaves tile the window
        let img = panels(width: 1000, height: 800, fills: [
            (CGRect(x: 0, y: 0, width: 1000, height: 80), 0.2),
            (CGRect(x: 0, y: 82, width: 250, height: 718), 0.15),
            (CGRect(x: 252, y: 82, width: 748, height: 718), 0.85),
        ])
        let s = SectionDetector.detect(in: img)
        let area = s.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(area, 1000 * 800, accuracy: 1)   // exact tiling, no gaps/overlaps
    }

    func testStrongOutlierAmongRowsSurvivesTheGridVeto() {
        // Pro Tools case: one full-width transport edge (fill 1.0) sitting ABOVE ~10 weaker, regularly
        // spaced track-row separators. The veto must keep the outlier so the transport splits off.
        var lines: [(pos: Int, fill: Double)] = [(90, 1.0)]                    // the transport edge
        for i in 0..<10 { lines.append((250 + i * 90, 0.55)) }                 // regular row separators
        XCTAssertFalse(SectionDetector.isRegularGrid(lines))                   // mixed strength ⇒ not a grid
        // a truly uniform grid (equal fill, equal spacing) IS vetoed
        let grid = (0..<10).map { (100 + $0 * 80, 0.9) }
        XCTAssertTrue(SectionDetector.isRegularGrid(grid))
    }

    // MARK: - image-aware seams (Codex P1: pink section lines through photo interiors)

    /// A mid-gray window with panel fills PLUS a "photo": a block of IRREGULAR vertical stripes whose
    /// interior edges form strong towers — what leaks into the section cut on real screens. Irregular
    /// on purpose: a regular stripe grid would be vetoed as a table, and real photos are not grids.
    private func sceneWithPhoto(width: Int, height: Int, fills: [(CGRect, CGFloat)], photo: CGRect) -> CGImage {
        makeCGImage(width: width, height: height) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (r, g) in fills { ctx.setFillColor(gray: g, alpha: 1); ctx.fill(r) }
            let widths = [18, 47, 29, 63, 22, 41, 35, 56]
            var x = Int(photo.minX), i = 0
            while x < Int(photo.maxX) {
                let w = min(widths[i % widths.count], Int(photo.maxX) - x)
                ctx.setFillColor(gray: i % 2 == 0 ? 0.1 : 0.9, alpha: 1)
                ctx.fill(CGRect(x: CGFloat(x), y: photo.minY, width: CGFloat(w), height: photo.height))
                x += w; i += 1
            }
        }
    }

    private func cutsInside(_ sections: [CGRect], _ photo: CGRect, margin: CGFloat = 40) -> Bool {
        sections.contains { $0.minX > photo.minX + margin && $0.minX < photo.maxX - margin }
    }

    func testImageInteriorEdgesDoNotBecomeSeams() {
        let photo = CGRect(x: 300, y: 100, width: 400, height: 600)   // 75% of the height: towers clear fillMin
        let img = sceneWithPhoto(width: 1000, height: 800, fills: [], photo: photo)
        XCTAssertTrue(cutsInside(SectionDetector.detect(in: img), photo),
                      "control: without exclusion the photo's stripes DO cut the window — else this test proves nothing")
        XCTAssertFalse(cutsInside(SectionDetector.detect(in: img, excluding: [photo]), photo),
                       "a photo's interior texture must not propose a panel seam")
    }

    func testPanelSeamBesideImageSurvives() {
        let photo = CGRect(x: 500, y: 100, width: 300, height: 400)
        let img = sceneWithPhoto(width: 1000, height: 800, fills: [
            (CGRect(x: 0, y: 0, width: 300, height: 800), 0.15),
            (CGRect(x: 302, y: 0, width: 698, height: 800), 0.85)], photo: photo)
        let s = SectionDetector.detect(in: img, excluding: [photo])
        XCTAssertTrue(s.contains { abs($0.minX - 300) < 40 || abs($0.maxX - 300) < 40 },
                      "the sidebar edge is entirely outside the image and must survive")
        XCTAssertFalse(cutsInside(s, photo))
    }

    func testSeamSupportedOnlyInsideImageIsRejected() {
        // One hard vertical line, 95% of the window tall — but entirely INSIDE the photo.
        let photo = CGRect(x: 100, y: 20, width: 800, height: 760)
        let img = makeCGImage(width: 1000, height: 800) { ctx in
            ctx.translateBy(x: 0, y: 800); ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
            ctx.setFillColor(gray: 0.3, alpha: 1); ctx.fill(CGRect(x: 100, y: 20, width: 400, height: 760))
            ctx.setFillColor(gray: 0.8, alpha: 1); ctx.fill(CGRect(x: 500, y: 20, width: 400, height: 760))
        }
        XCTAssertTrue(SectionDetector.detect(in: img).contains { abs($0.minX - 500) < 40 }, "control: the line cuts without exclusion")
        XCTAssertFalse(SectionDetector.detect(in: img, excluding: [photo]).contains { abs($0.minX - 500) < 40 },
                       "5% of its span is outside the image — that is the photo's content, not a seam")
    }

    func testDividerPassingUnderImageKeepsContinuity() {
        // A full-height sidebar seam at x≈400 with a photo straddling it: the seam's 50% outside support
        // is enough, and the neutral interior must not BREAK its run.
        let photo = CGRect(x: 300, y: 200, width: 200, height: 400)
        let img = sceneWithPhoto(width: 1000, height: 800, fills: [
            (CGRect(x: 0, y: 0, width: 400, height: 800), 0.15),
            (CGRect(x: 402, y: 0, width: 598, height: 800), 0.85)], photo: photo)
        let s = SectionDetector.detect(in: img, excluding: [photo])
        XCTAssertTrue(s.contains { abs($0.minX - 400) < 40 || abs($0.maxX - 400) < 40 },
                      "outside support 50% ≥ 40% at 100% fill — the seam survives the photo over it")
    }

    func testNoImagesIsTheOldCut() {   // excluding: [] must be byte-identical to the previous behaviour
        let img = panels(width: 1000, height: 800, fills: [
            (CGRect(x: 0, y: 0, width: 300, height: 800), 0.15),
            (CGRect(x: 302, y: 0, width: 698, height: 800), 0.85)])
        XCTAssertEqual(SectionDetector.detect(in: img), SectionDetector.detect(in: img, excluding: []))
    }
}

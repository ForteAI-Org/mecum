import XCTest
import CoreGraphics
import ImageIO
@testable import CVBackend

/// CHECKBOX / RADIO pixel states — the zero-AX read for controls whose state lives INSIDE them.
/// Numbers here are the ones measured on the real corpus (`~/.fflow/fixtures/davinci-project-settings.png`
/// and the Premiere Export frame): DaVinci's dark Qt panel reads luma 41, an empty field 31 (dimmed 37),
/// a selected radio's dot 255, a dimmed checkmark ~90; Premiere's switch knobs and destination logos are
/// the negatives that must never read as a mark.
final class MarkStateReaderTests: XCTestCase {

    // MARK: painters — a control centred on a panel, at 3× its own size (what `markMetrics` pads into)

    private func canvas(_ control: CGRect, panel: CGFloat, _ paint: (CGContext) -> Void) -> CGImage {
        let side = Int(control.width * 3)
        return makeCGImage(width: side, height: side) { ctx in
            ctx.setFillColor(gray: panel / 255, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            paint(ctx)
        }
    }
    private var control: CGRect { CGRect(x: 28, y: 28, width: 28, height: 28) }

    /// A radio: rim ring, empty field, and (when selected) a filled centre dot.
    private func radio(selected: Bool, panel: CGFloat, rim: CGFloat, field: CGFloat, dot: CGFloat) -> CGImage {
        canvas(control, panel: panel) { ctx in
            ctx.setFillColor(gray: rim / 255, alpha: 1);   ctx.fillEllipse(in: control)
            ctx.setFillColor(gray: field / 255, alpha: 1); ctx.fillEllipse(in: control.insetBy(dx: 3, dy: 3))
            guard selected else { return }
            ctx.setFillColor(gray: dot / 255, alpha: 1);   ctx.fillEllipse(in: control.insetBy(dx: 7, dy: 7))
        }
    }
    /// A checkbox: rim box, empty field, and (when checked) a tick stroked across the middle.
    private func checkbox(checked: Bool, panel: CGFloat, rim: CGFloat, field: CGFloat, tick: CGFloat) -> CGImage {
        canvas(control, panel: panel) { ctx in
            ctx.setFillColor(gray: rim / 255, alpha: 1);   ctx.fill(control)
            ctx.setFillColor(gray: field / 255, alpha: 1); ctx.fill(control.insetBy(dx: 3, dy: 3))
            guard checked else { return }
            ctx.setStrokeColor(gray: tick / 255, alpha: 1); ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: control.minX + 7, y: control.midY))
            ctx.addLine(to: CGPoint(x: control.midX - 1, y: control.minY + 7))
            ctx.addLine(to: CGPoint(x: control.maxX - 6, y: control.maxY - 7))
            ctx.strokePath()
        }
    }

    // MARK: dark theme — the measured failure, inverted

    func testDarkSelectedRadioReadsOn() {
        let img = radio(selected: true, panel: 41, rim: 8, field: 31, dot: 255)
        XCTAssertEqual(ToggleStateReader.markState(of: img, control: control), "on")
    }
    func testDarkUnselectedRadioReadsOff() {
        let img = radio(selected: false, panel: 41, rim: 8, field: 31, dot: 255)
        XCTAssertEqual(ToggleStateReader.markState(of: img, control: control), "off")
    }
    func testDarkCheckedBoxReadsOn() {
        let img = checkbox(checked: true, panel: 41, rim: 8, field: 37, tick: 90)   // DIMMED tick — the "Align Clips" case
        XCTAssertEqual(ToggleStateReader.markState(of: img, control: control), "on")
    }
    func testDarkUncheckedBoxReadsOff() {
        let img = checkbox(checked: false, panel: 41, rim: 8, field: 37, tick: 90)
        XCTAssertEqual(ToggleStateReader.markState(of: img, control: control), "off")
    }
    func testDarkThemeIsDetectedFromTheSurroundingPanel() {
        let m = ToggleStateReader.markMetrics(of: radio(selected: true, panel: 41, rim: 8, field: 31, dot: 255),
                                              control: control)
        XCTAssertEqual(m?.isDark, true)
    }

    // MARK: light theme — the SAME reader, polarity mirrored

    func testLightSelectedRadioReadsOn() {
        let img = radio(selected: true, panel: 236, rim: 150, field: 252, dot: 60)
        XCTAssertEqual(ToggleStateReader.markState(of: img, control: control), "on")
    }
    func testLightUnselectedRadioReadsOff() {
        let img = radio(selected: false, panel: 236, rim: 150, field: 252, dot: 60)
        XCTAssertEqual(ToggleStateReader.markState(of: img, control: control), "off")
    }
    func testLightCheckedBoxReadsOn() {
        let img = checkbox(checked: true, panel: 236, rim: 150, field: 252, tick: 40)
        XCTAssertEqual(ToggleStateReader.markState(of: img, control: control), "on")
    }
    func testLightUncheckedBoxReadsOff() {
        let img = checkbox(checked: false, panel: 236, rim: 150, field: 252, tick: 40)
        XCTAssertEqual(ToggleStateReader.markState(of: img, control: control), "off")
    }
    func testLightThemeIsDetectedFromTheSurroundingPanel() {
        let m = ToggleStateReader.markMetrics(of: checkbox(checked: false, panel: 236, rim: 150, field: 252, tick: 40),
                                              control: control)
        XCTAssertEqual(m?.isDark, false)
    }

    // MARK: negatives — what must NEVER read as a checkbox/radio

    func testSwitchKnobIsNotAMark() {   // a filled disc: its FIELD is the disc, nothing like the panel
        let img = canvas(control, panel: 30) { ctx in
            ctx.setFillColor(gray: 200 / 255, alpha: 1); ctx.fillEllipse(in: self.control)
        }
        XCTAssertNil(ToggleStateReader.markState(of: img, control: control))
    }
    func testPlatedLogoIsNotAMark() {   // rounded plate + glyph (Premiere's Facebook/Behance destinations)
        let img = canvas(control, panel: 30) { ctx in
            ctx.setFillColor(gray: 200 / 255, alpha: 1); ctx.fill(self.control)
            ctx.setFillColor(gray: 30 / 255, alpha: 1);  ctx.fill(self.control.insetBy(dx: 9, dy: 4))
        }
        XCTAssertNil(ToggleStateReader.markState(of: img, control: control))
    }
    func testRaisedPlateButtonIsNotAMark() {
        // Safari's rounded page-settings button: a glyph on a plate that sits ABOVE the page, where a
        // checkbox's interior is recessed BELOW it. Measured on the real frame: panel 40, plate 60.
        let img = canvas(control, panel: 40) { ctx in
            ctx.setFillColor(gray: 60 / 255, alpha: 1); ctx.fillEllipse(in: self.control)
            ctx.setFillColor(gray: 230 / 255, alpha: 1)
            ctx.fill(CGRect(x: self.control.minX + 8, y: self.control.midY - 1, width: 12, height: 3))
            ctx.fill(CGRect(x: self.control.minX + 6, y: self.control.midY + 6, width: 12, height: 3))
        }
        XCTAssertNil(ToggleStateReader.markState(of: img, control: control))
    }

    func testUnframedGlyphIsNotAMark() {
        // A monochrome app logo: strokes on the bare panel, no border and no interior of its own. Its INK
        // looks exactly like a tick's — the missing frame is the only thing that separates them.
        let img = canvas(control, panel: 30) { ctx in
            ctx.setStrokeColor(gray: 230 / 255, alpha: 1); ctx.setLineWidth(4)
            ctx.move(to: CGPoint(x: self.control.minX + 5, y: self.control.minY + 5))
            ctx.addLine(to: CGPoint(x: self.control.maxX - 5, y: self.control.maxY - 5))
            ctx.move(to: CGPoint(x: self.control.maxX - 5, y: self.control.minY + 5))
            ctx.addLine(to: CGPoint(x: self.control.minX + 5, y: self.control.maxY - 5))
            ctx.strokePath()
        }
        XCTAssertNil(ToggleStateReader.markState(of: img, control: control))
    }

    func testFlatPanelIsNotAMark() {   // nothing drawn at all — no frame, no mark, no verdict
        XCTAssertNil(ToggleStateReader.markState(of: canvas(control, panel: 41) { _ in }, control: control))
    }

    // MARK: the pipeline seam — a confirmed mark leaves the switch detector's input

    func testConfirmedMarkIsRemovedFromTheSwitchDetectorsSegments() {
        let img = radio(selected: true, panel: 41, rim: 8, field: 31, dot: 255)
        let other = CGRect(x: 0, y: 0, width: 12, height: 8)   // far from the radio: its own union
        let (marks, rest) = ToggleStateReader.markControls(segments: [control, other], in: img)
        XCTAssertEqual(marks.map(\.state), ["on"])
        XCTAssertEqual(marks.first?.rect, control)
        XCTAssertEqual(rest, [other])          // the radio is gone — it can no longer be read as a knob
    }
    func testUnconfirmedSquareStaysAvailableToTheSwitchDetector() {
        let img = canvas(control, panel: 30) { ctx in
            ctx.setFillColor(gray: 200 / 255, alpha: 1); ctx.fillEllipse(in: self.control)
        }
        let (marks, rest) = ToggleStateReader.markControls(segments: [control], in: img)
        XCTAssertTrue(marks.isEmpty)
        XCTAssertEqual(rest, [control])
    }

    // MARK: real corpus — the exact measured failure, on the real frame (skipped when unavailable)

    func testDaVinciDarkQtRealCrops() throws {
        let path = ("~/.fflow/fixtures/davinci-project-settings.png" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw XCTSkip("fixture corpus not on this machine — see scripts/check-fixtures.sh") }
        // Vision-only read all three of these as [off] before this reader existed.
        let on: [(String, CGRect)] = [
            ("Square (selected radio)",        CGRect(x: 911, y: 315, width: 28, height: 28)),
            ("Dual link (selected radio)",     CGRect(x: 911, y: 1255, width: 28, height: 28)),
            ("Align Clips (checked, dimmed)",  CGRect(x: 913, y: 672, width: 27, height: 28)),
            // …and as the SEGMENTER actually boxes them (the mark alone, not the full outline):
            ("Square dot as segmented",        CGRect(x: 917, y: 321, width: 20, height: 20)),
            ("Dual link dot as segmented",     CGRect(x: 917, y: 1259, width: 20, height: 20)),
            ("Align Clips tick as segmented",  CGRect(x: 917, y: 676, width: 22, height: 21)),
        ]
        let off: [(String, CGRect)] = [
            ("Use vertical resolution",  CGRect(x: 913, y: 263, width: 27, height: 28)),
            ("16:9 anamorphic (dimmed)", CGRect(x: 911, y: 363, width: 28, height: 28)),
            ("Cinemascope",              CGRect(x: 911, y: 458, width: 28, height: 28)),
            ("Use drop frame (dimmed)",  CGRect(x: 913, y: 573, width: 27, height: 28)),
            ("Use 1080PsF",              CGRect(x: 913, y: 1006, width: 27, height: 28)),
            ("Single link",              CGRect(x: 911, y: 1207, width: 28, height: 28)),
            ("Quad link",                CGRect(x: 911, y: 1302, width: 28, height: 28)),
        ]
        for (name, r) in on { XCTAssertEqual(ToggleStateReader.markState(of: img, control: r), "on", name) }
        for (name, r) in off { XCTAssertEqual(ToggleStateReader.markState(of: img, control: r), "off", name) }
    }
}

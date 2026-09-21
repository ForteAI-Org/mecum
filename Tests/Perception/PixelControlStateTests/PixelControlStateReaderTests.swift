//
//  PixelControlStateReaderTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import ImageIO
import PerceptionCore
import XCTest
@testable import PixelControlState

/// Builds a deterministic sRGB RGBA8 image from a draw closure.
private func makeCGImage(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    draw(context)
    return try XCTUnwrap(context.makeImage())
}

/// SWITCH pixel states: a pill with a light knob at one end, read for applications that expose no
/// control state at all.
final class ToggleStateTests: XCTestCase {

    /// Synthetic switch: dark track and a bright knob on one side, in top-left authored coordinates.
    private func toggle(knobRight: Bool, w: Int = 40, h: Int = 20) throws -> CGImage {
        try makeCGImage(width: w, height: h) { context in
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(gray: 0.95, alpha: 1)
            context.fillEllipse(in: CGRect(x: knobRight ? w - h : 0, y: 0, width: h, height: h))
        }
    }

    func testKnobRightReadsOn() throws {
        XCTAssertEqual(PixelControlStateReader.state(of: try toggle(knobRight: true)), .on)
    }

    func testKnobLeftReadsOff() throws {
        XCTAssertEqual(PixelControlStateReader.state(of: try toggle(knobRight: false)), .off)
    }

    func testFlatCropIsUnknown() throws {
        let flat = try makeCGImage(width: 40, height: 20) { context in
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        XCTAssertNil(PixelControlStateReader.state(of: flat))   // no guess on ambiguity
    }

    func testShapeGate() {
        XCTAssertTrue(PixelControlStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 36, height: 18)))    // 2.0
        XCTAssertTrue(PixelControlStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 72, height: 36)))    // retina
        XCTAssertFalse(PixelControlStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 18, height: 18)))   // square icon
        XCTAssertFalse(PixelControlStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 200, height: 14)))  // divider
        XCTAssertFalse(PixelControlStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 16, height: 8)))    // too small
    }

    func testOversizedPillIsNotToggleShaped() {   // measured: a 161x86 browser box shape-passed as a switch
        XCTAssertFalse(PixelControlStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 161, height: 86)))
        XCTAssertTrue(PixelControlStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 88, height: 44)))    // retina switch
    }

    // MARK: the role, over a candidate the grouper placed on a whole frame

    func testCandidateOnAFrameReadsTheSwitchUnderIt() throws {
        let image = try makeCGImage(width: 120, height: 60) { context in
            context.setFillColor(gray: 0.1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: 20, y: 20, width: 40, height: 20))
            context.setFillColor(gray: 0.95, alpha: 1)
            context.fillEllipse(in: CGRect(x: 40, y: 20, width: 20, height: 20))
        }
        let pill = CGRect(x: 20, y: 20, width: 40, height: 20)
        let state = PixelControlStateReader().state(of: ControlCandidate(box: pill, shape: .toggle), in: image)
        XCTAssertEqual(state, .on)
    }

    func testAPillBusyAtBothEndsIsNotASwitch() throws {
        // The X social logo's shape: glyph strokes at both ends, no flat knob or empty track.
        let pill = CGRect(x: 0, y: 0, width: 40, height: 20)
        let image = try makeCGImage(width: 40, height: 20) { context in
            context.setFillColor(gray: 0.15, alpha: 1)
            context.fill(pill)
            context.setStrokeColor(gray: 0.95, alpha: 1)
            context.setLineWidth(3)
            for offset in [0, 20] as [CGFloat] {
                context.move(to: CGPoint(x: offset + 3, y: 3))
                context.addLine(to: CGPoint(x: offset + 17, y: 17))
                context.move(to: CGPoint(x: offset + 17, y: 3))
                context.addLine(to: CGPoint(x: offset + 3, y: 17))
            }
            context.strokePath()
        }
        XCTAssertNil(PixelControlStateReader().state(of: ControlCandidate(box: pill, shape: .toggle), in: image))
    }
}

/// CHECKBOX and RADIO pixel states, the read for a control whose state lives INSIDE it. The numbers
/// here are the ones measured on the real corpus (`~/.fflow/fixtures/davinci-project-settings.png`
/// and the Premiere Export frame): DaVinci's dark Qt panel reads luma 41, an empty field 31 (dimmed
/// 37), a selected radio's dot 255, a dimmed checkmark about 90; Premiere's switch knobs and
/// destination logos are the negatives that must never read as a mark.
final class MarkStateTests: XCTestCase {

    // MARK: painters, a control centred on a panel at 3x its own size, what `markMetrics` pads into

    private func canvas(_ control: CGRect, panel: CGFloat, _ paint: (CGContext) -> Void) throws -> CGImage {
        let side = Int(control.width * 3)
        return try makeCGImage(width: side, height: side) { context in
            context.setFillColor(gray: panel / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            paint(context)
        }
    }

    private var control: CGRect { CGRect(x: 28, y: 28, width: 28, height: 28) }

    /// A radio: rim ring, empty field, and when selected a filled centre dot.
    private func radio(selected: Bool, panel: CGFloat, rim: CGFloat, field: CGFloat, dot: CGFloat) throws -> CGImage {
        try canvas(control, panel: panel) { context in
            context.setFillColor(gray: rim / 255, alpha: 1)
            context.fillEllipse(in: control)
            context.setFillColor(gray: field / 255, alpha: 1)
            context.fillEllipse(in: control.insetBy(dx: 3, dy: 3))
            guard selected else { return }
            context.setFillColor(gray: dot / 255, alpha: 1)
            context.fillEllipse(in: control.insetBy(dx: 7, dy: 7))
        }
    }

    /// A checkbox: rim box, empty field, and when checked a tick stroked across the middle.
    private func checkbox(checked: Bool, panel: CGFloat, rim: CGFloat, field: CGFloat, tick: CGFloat) throws -> CGImage {
        try canvas(control, panel: panel) { context in
            context.setFillColor(gray: rim / 255, alpha: 1)
            context.fill(control)
            context.setFillColor(gray: field / 255, alpha: 1)
            context.fill(control.insetBy(dx: 3, dy: 3))
            guard checked else { return }
            context.setStrokeColor(gray: tick / 255, alpha: 1)
            context.setLineWidth(3)
            context.move(to: CGPoint(x: control.minX + 7, y: control.midY))
            context.addLine(to: CGPoint(x: control.midX - 1, y: control.minY + 7))
            context.addLine(to: CGPoint(x: control.maxX - 6, y: control.maxY - 7))
            context.strokePath()
        }
    }

    // MARK: dark theme, the measured failure, inverted

    func testDarkSelectedRadioReadsOn() throws {
        let image = try radio(selected: true, panel: 41, rim: 8, field: 31, dot: 255)
        XCTAssertEqual(PixelControlStateReader.markState(of: image, control: control), .on)
    }

    func testDarkUnselectedRadioReadsOff() throws {
        let image = try radio(selected: false, panel: 41, rim: 8, field: 31, dot: 255)
        XCTAssertEqual(PixelControlStateReader.markState(of: image, control: control), .off)
    }

    func testDarkCheckedBoxReadsOn() throws {   // DIMMED tick, the "Align Clips" case
        let image = try checkbox(checked: true, panel: 41, rim: 8, field: 37, tick: 90)
        XCTAssertEqual(PixelControlStateReader.markState(of: image, control: control), .on)
    }

    func testDarkUncheckedBoxReadsOff() throws {
        let image = try checkbox(checked: false, panel: 41, rim: 8, field: 37, tick: 90)
        XCTAssertEqual(PixelControlStateReader.markState(of: image, control: control), .off)
    }

    func testDarkThemeIsDetectedFromTheSurroundingPanel() throws {
        let image = try radio(selected: true, panel: 41, rim: 8, field: 31, dot: 255)
        XCTAssertEqual(PixelControlStateReader.markMetrics(of: image, control: control)?.isDark, true)
    }

    // MARK: light theme, the SAME reader with the polarity mirrored

    func testLightSelectedRadioReadsOn() throws {
        let image = try radio(selected: true, panel: 236, rim: 150, field: 252, dot: 60)
        XCTAssertEqual(PixelControlStateReader.markState(of: image, control: control), .on)
    }

    func testLightUnselectedRadioReadsOff() throws {
        let image = try radio(selected: false, panel: 236, rim: 150, field: 252, dot: 60)
        XCTAssertEqual(PixelControlStateReader.markState(of: image, control: control), .off)
    }

    func testLightCheckedBoxReadsOn() throws {
        let image = try checkbox(checked: true, panel: 236, rim: 150, field: 252, tick: 40)
        XCTAssertEqual(PixelControlStateReader.markState(of: image, control: control), .on)
    }

    func testLightUncheckedBoxReadsOff() throws {
        let image = try checkbox(checked: false, panel: 236, rim: 150, field: 252, tick: 40)
        XCTAssertEqual(PixelControlStateReader.markState(of: image, control: control), .off)
    }

    func testLightThemeIsDetectedFromTheSurroundingPanel() throws {
        let image = try checkbox(checked: false, panel: 236, rim: 150, field: 252, tick: 40)
        XCTAssertEqual(PixelControlStateReader.markMetrics(of: image, control: control)?.isDark, false)
    }

    // MARK: negatives, what must NEVER read as a checkbox or radio

    func testSwitchKnobIsNotAMark() throws {   // a filled disc: its FIELD is the disc, nothing like the panel
        let image = try canvas(control, panel: 30) { context in
            context.setFillColor(gray: 200 / 255, alpha: 1)
            context.fillEllipse(in: self.control)
        }
        XCTAssertNil(PixelControlStateReader.markState(of: image, control: control))
    }

    func testPlatedLogoIsNotAMark() throws {   // rounded plate and glyph: Premiere's destinations
        let image = try canvas(control, panel: 30) { context in
            context.setFillColor(gray: 200 / 255, alpha: 1)
            context.fill(self.control)
            context.setFillColor(gray: 30 / 255, alpha: 1)
            context.fill(self.control.insetBy(dx: 9, dy: 4))
        }
        XCTAssertNil(PixelControlStateReader.markState(of: image, control: control))
    }

    func testRaisedPlateButtonIsNotAMark() throws {
        // Safari's rounded page-settings button: a glyph on a plate that sits ABOVE the page, where a
        // checkbox's interior is recessed BELOW it. Measured on the real frame: panel 40, plate 60.
        let image = try canvas(control, panel: 40) { context in
            context.setFillColor(gray: 60 / 255, alpha: 1)
            context.fillEllipse(in: self.control)
            context.setFillColor(gray: 230 / 255, alpha: 1)
            context.fill(CGRect(x: self.control.minX + 8, y: self.control.midY - 1, width: 12, height: 3))
            context.fill(CGRect(x: self.control.minX + 6, y: self.control.midY + 6, width: 12, height: 3))
        }
        XCTAssertNil(PixelControlStateReader.markState(of: image, control: control))
    }

    func testUnframedGlyphIsNotAMark() throws {
        // A monochrome app logo: strokes on the bare panel, no border and no interior of its own. Its
        // INK looks exactly like a tick's, and the missing frame is the only thing separating them.
        let image = try canvas(control, panel: 30) { context in
            context.setStrokeColor(gray: 230 / 255, alpha: 1)
            context.setLineWidth(4)
            context.move(to: CGPoint(x: self.control.minX + 5, y: self.control.minY + 5))
            context.addLine(to: CGPoint(x: self.control.maxX - 5, y: self.control.maxY - 5))
            context.move(to: CGPoint(x: self.control.maxX - 5, y: self.control.minY + 5))
            context.addLine(to: CGPoint(x: self.control.minX + 5, y: self.control.maxY - 5))
            context.strokePath()
        }
        XCTAssertNil(PixelControlStateReader.markState(of: image, control: control))
    }

    func testFlatPanelIsNotAMark() throws {   // nothing drawn at all: no frame, no mark, no verdict
        let image = try canvas(control, panel: 41) { _ in }
        XCTAssertNil(PixelControlStateReader.markState(of: image, control: control))
    }

    // MARK: real corpus, the exact measured failure on the real frame, skipped when unavailable

    func testDaVinciDarkQtRealCrops() throws {
        let path = ("~/.fflow/fixtures/davinci-project-settings.png" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw XCTSkip("fixture corpus not on this machine — see scripts/check-fixtures.sh") }
        // Vision alone read all three of these as off before this reader existed.
        let on: [(String, CGRect)] = [
            ("Square (selected radio)",        CGRect(x: 911, y: 315, width: 28, height: 28)),
            ("Dual link (selected radio)",     CGRect(x: 911, y: 1255, width: 28, height: 28)),
            ("Align Clips (checked, dimmed)",  CGRect(x: 913, y: 672, width: 27, height: 28)),
            // …and as the SEGMENTER actually boxes them, the mark alone rather than the full outline:
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
        for (name, rect) in on {
            XCTAssertEqual(PixelControlStateReader.markState(of: image, control: rect), .on, name)
        }
        for (name, rect) in off {
            XCTAssertEqual(PixelControlStateReader.markState(of: image, control: rect), .off, name)
        }
    }
}

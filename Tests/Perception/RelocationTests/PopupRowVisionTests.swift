import XCTest
import CoreGraphics
import CoreText
import LocatorCore
import OCRSupport
@testable import Relocation

/// The zero-AX pop-up path (ticket 07): a custom-drawn list's own pixels become ONE ELEMENT PER ITEM,
/// in exactly the shape ticket 06's AX rows have, so everything downstream (the "open menu" section,
/// the act path's hover + vision-verified selection, the sightings exclusion) treats both the same.
final class PopupRowVisionTests: XCTestCase {
    private func row(_ t: String, _ r: CGRect) -> PopupRowSegmenter.Row { .init(text: t, rect: r, textRect: r) }

    // MARK: - Element shape (matches AXPopupReader's, ticket 06)

    func testElementsCarryTheMenuRowShape() {
        let popup = CGRect(x: 400, y: 300, width: 200, height: 150)
        let rows = [row("ProRes 422", CGRect(x: 404, y: 310, width: 192, height: 24)),
                    row("H.264", CGRect(x: 404, y: 334, width: 192, height: 24))]

        let els = PopupRowVision.elements(from: rows, popup: popup,
                                          windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))

        XCTAssertEqual(els.map(\.label), ["ProRes 422", "H.264"])
        XCTAssertEqual(els.map(\.role), ["AXMenuItem", "AXMenuItem"])
        XCTAssertEqual(els.map(\.kind), ["control", "control"])
        XCTAssertTrue(els.allSatisfy { $0.does?.isEmpty == false }, "a menu row must say what it is")
        XCTAssertTrue(els.allSatisfy { $0.unlabeled != true })
    }

    /// The one invariant a click depends on: `act` turns `pos` back into a screen point against the
    /// SAME window frame the scene was perceived from. That round trip must land on the row.
    func testPositionRoundTripsToTheRowsCentre() {
        let win = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let popup = CGRect(x: 400, y: 300, width: 200, height: 150)
        let r = CGRect(x: 404, y: 310, width: 192, height: 24)

        let el = PopupRowVision.elements(from: [row("ProRes 422", r)], popup: popup, windowFrame: win)[0]

        let pt = CGPoint(x: win.minX + (el.pos[0] + el.pos[2] / 2) * win.width,
                         y: win.minY + (el.pos[1] + el.pos[3] / 2) * win.height)
        XCTAssertEqual(pt.x, r.midX, accuracy: 0.001)
        XCTAssertEqual(pt.y, r.midY, accuracy: 0.001)
    }

    /// A dropdown that hangs BELOW its window still points at the right pixels: the normalized position
    /// is allowed to leave 0…1 because the act transform is linear, and lying about it would misclick.
    func testRowsOutsideTheWindowFrameStillRoundTrip() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let popup = CGRect(x: 400, y: 380, width: 200, height: 150)
        let r = CGRect(x: 404, y: 460, width: 192, height: 24)

        let el = PopupRowVision.elements(from: [row("48 kHz", r)], popup: popup, windowFrame: win)[0]

        XCTAssertGreaterThan(el.pos[1], 1.0, "a row below the window must not be clamped into it")
        let y = win.minY + (el.pos[1] + el.pos[3] / 2) * win.height
        XCTAssertEqual(y, r.midY, accuracy: 0.001)
    }

    /// Two rows reading the same thing stay individually addressable — same rule as the AX half.
    func testDuplicateLabelsAreNumbered() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 100)
        let rows = [row("Custom", CGRect(x: 0, y: 0, width: 200, height: 24)),
                    row("Custom", CGRect(x: 0, y: 24, width: 200, height: 24))]

        let els = PopupRowVision.elements(from: rows, popup: popup,
                                          windowFrame: CGRect(x: 0, y: 0, width: 200, height: 100))

        XCTAssertEqual(els.map(\.label), ["Custom", "Custom #2"])
        XCTAssertEqual(Set(els.map(\.id)).count, 2, "two rows must not share an id")
    }

    func testNoWindowFrameYieldsNothing() {
        XCTAssertTrue(PopupRowVision.elements(from: [row("x", CGRect(x: 0, y: 0, width: 10, height: 10))],
                                              popup: CGRect(x: 0, y: 0, width: 10, height: 10),
                                              windowFrame: .zero).isEmpty)
    }

    // MARK: - Replacing the main capture's garble

    /// The main-window capture reads a GPU-drawn pop-up as tiny garble ("Dport", "MWPLE"). Once the
    /// pop-up has been read at native scale, those are the SAME PIXELS read worse: they must not stay
    /// in the scene competing with the rows.
    func testCVInsideThePopupIsDropped() {
        let box: [Double] = [0.4, 0.3, 0.2, 0.2]     // the popup, window-normalized
        let inside = SceneElement(id: "a", kind: "text", label: "Dport", pos: [0.45, 0.35, 0.05, 0.02])
        let outside = SceneElement(id: "b", kind: "text", label: "Export Settings", pos: [0.1, 0.1, 0.2, 0.03])
        let icon = SceneElement(id: "c", kind: "icon", label: "", pos: [0.42, 0.32, 0.01, 0.01], unlabeled: true)

        let kept = PopupRowVision.dropCVInsidePopup(cv: [inside, outside, icon], popupNormalized: box)

        XCTAssertEqual(kept.map(\.id), ["b", "c"], "the popup's own garble goes; the window behind it stays")
    }

    /// The complaint that made ticket 07 look broken was "~30 UNLABELED icon fragments on a grid": the
    /// window capture's read of the very pixels the row cut has now enumerated, one box per word. Once
    /// an adopted row band owns those pixels, a fragment inside it is the same word read worse — map
    /// noise the agent has to look past. A fragment OUTSIDE every band is different: a header strip or
    /// the scroll arrow the rows never covered, geography nothing else accounts for, so it stays.
    func testUnlabeledFragmentsInsideAnAdoptedRowBandAreDropped() {
        let popup: [Double] = [0, 0, 0.5, 0.5]
        let bands: [[Double]] = [[0, 0.10, 0.5, 0.10], [0, 0.20, 0.5, 0.10]]
        let inBand = SceneElement(id: "frag", kind: "icon", label: "", pos: [0.10, 0.13, 0.02, 0.01], unlabeled: true)
        let aboveBands = SceneElement(id: "header", kind: "icon", label: "", pos: [0.10, 0.02, 0.02, 0.01], unlabeled: true)
        let outsidePopup = SceneElement(id: "far", kind: "icon", label: "", pos: [0.8, 0.8, 0.02, 0.01], unlabeled: true)
        let namedInside = SceneElement(id: "garble", kind: "text", label: "Dport", pos: [0.10, 0.23, 0.05, 0.01])

        let kept = PopupRowVision.dropCVInsidePopup(cv: [inBand, aboveBands, outsidePopup, namedInside],
                                                    popupNormalized: popup, rowBands: bands)

        XCTAssertEqual(kept.map(\.id), ["header", "far"], "kept \(kept.map(\.id))")
    }

    /// No adopted rows, no bands: the earlier promise holds unchanged — an unlabeled box inside the
    /// pop-up survives, because nothing has accounted for those pixels yet.
    func testWithoutRowBandsUnlabeledFragmentsStay() {
        let icon = SceneElement(id: "c", kind: "icon", label: "", pos: [0.42, 0.32, 0.01, 0.01], unlabeled: true)
        XCTAssertEqual(PopupRowVision.dropCVInsidePopup(cv: [icon], popupNormalized: [0.4, 0.3, 0.2, 0.2]).map(\.id),
                       ["c"])
    }

    func testDropIsANoOpWithoutAPopupBox() {
        let els = [SceneElement(id: "a", kind: "text", label: "x", pos: [0.5, 0.5, 0.1, 0.1])]
        XCTAssertEqual(PopupRowVision.dropCVInsidePopup(cv: els, popupNormalized: []).map(\.id), ["a"])
    }

    // MARK: - Real pixels, end to end (OCR → rows), no screen and no permissions

    /// The measured failure, reproduced offline: a rendered dropdown whose items OCR as separate lines
    /// must come back as SIX addressable items — not one run-on blob — and the row with a right-hand
    /// shortcut column must stay ONE item.
    func testRenderedDropdownEnumeratesItsItems() throws {
        let items = ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"]
        let image = dropdownImage(items: items, shortcutOn: "Copy", shortcut: "K",
                                  width: 380, pitch: 44, fontSize: 22)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))

        let rows = PopupRowVision.rows(in: image, popupGlobalPt: frame)

        XCTAssertEqual(rows.count, items.count, "read \(rows.map(\.text))")
        XCTAssertEqual(rows.map { String($0.text.split(separator: " ").first ?? "") },
                       ["Undo", "Redo", "Cut", "Copy", "Paste", "Select"], "read \(rows.map(\.text))")
        let copy = try XCTUnwrap(rows.first { $0.text.hasPrefix("Copy") })
        XCTAssertTrue(copy.text.contains("K"), "the shortcut column must stay on its own row: '\(copy.text)'")
    }

    /// Light-on-dark is the case that matters (every custom-drawn list Locator has met is a dark theme).
    func testRenderedDarkDropdownEnumeratesItsItems() {
        let items = ["ProRes", "DNxHR", "H.264", "HEVC"]
        let image = dropdownImage(items: items, dark: true, width: 320, pitch: 40, fontSize: 20)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))

        let rows = PopupRowVision.rows(in: image, popupGlobalPt: frame)

        XCTAssertEqual(rows.count, items.count, "read \(rows.map(\.text))")
    }

    /// Rows map into the pop-up's GLOBAL frame when the capture is retina (2 px per point).
    func testRetinaCaptureMapsRowsBackToPoints() {
        let image = dropdownImage(items: ["Alpha", "Beta", "Gamma"], width: 400, pitch: 48, fontSize: 24)
        let popup = CGRect(x: 700, y: 200, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)

        let rows = PopupRowVision.rows(in: image, popupGlobalPt: popup)

        XCTAssertEqual(rows.count, 3, "read \(rows.map(\.text))")
        for r in rows {
            XCTAssertTrue(popup.insetBy(dx: -1, dy: -1).contains(r.rect), "row \(r.rect) escaped popup \(popup)")
        }
        XCTAssertLessThan(rows[0].rect.midY, rows[1].rect.midY)
    }

    /// DaVinci's timeline-resolution list — the shape ticket 07's live acceptance targeted: a DARK list
    /// where every row is TWO columns ("3840 x 2160" … "Ultra HD") sitting a wide gap apart. Each row
    /// must come back as ONE item carrying both columns; two half-items would make the agent ask for a
    /// resolution by half its name and click a strip that is only half the row.
    func testDarkTwoColumnResolutionListKeepsEachRowWhole() {
        let list = [("1280 x 720", "HD 720P"), ("1920 x 1080", "HD"),
                    ("3840 x 2160", "Ultra HD"), ("4096 x 2160", "DCI 4K")]
        let image = dropdownImage(rows: list.map { (left: $0.0, right: $0.1) }, dark: true,
                                  width: 460, pitch: 44, fontSize: 21)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))

        let rows = PopupRowVision.rows(in: image, popupGlobalPt: frame)

        XCTAssertEqual(rows.count, list.count, "read \(rows.map(\.text))")
        // Whitespace-insensitive: whether Vision transcribes "3840 x 2160" or "3840x 2160" is its
        // business — the invariant this pins is that BOTH columns landed on the SAME row.
        func squeezed(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        for (i, want) in list.enumerated() where i < rows.count {
            let got = squeezed(rows[i].text)
            XCTAssertTrue(got.contains(squeezed(want.0)) && got.contains(squeezed(want.1)),
                          "row \(i) lost a column: '\(rows[i].text)' wanted '\(want.0)' + '\(want.1)'")
        }
    }

    // MARK: - Saying what the read did

    /// EVERY branch speaks, including the ones that change nothing. Ticket 07's live acceptance was
    /// declared FAILED against a deploy 34 minutes OLDER than the feature: the scene showed the
    /// pre-ticket garble, the timing log said nothing about pop-up rows (that binary had no such code),
    /// and the silence was read as "the row cut ran and produced fragments". A branch that only speaks
    /// when it succeeds cannot be told apart from a branch that is not in the binary at all.
    func testEveryOutcomeSpeaksAndTheOutcomesAreDistinguishable() {
        let all: [PopupRowVision.Outcome] = [.notCaptured, .belowTheBar(rows: 1), .adopted(rows: 11),
                                             .axAnswered(rows: 88), .off]

        XCTAssertEqual(Set(all.map(\.summary)).count, all.count, "two outcomes read the same in a log")
        XCTAssertTrue(all.allSatisfy { !$0.summary.isEmpty })
        XCTAssertTrue(PopupRowVision.Outcome.adopted(rows: 11).summary.contains("11"))
        XCTAssertTrue(PopupRowVision.Outcome.belowTheBar(rows: 1).summary.contains("1"))
        XCTAssertTrue(PopupRowVision.Outcome.axAnswered(rows: 88).summary.contains("88"))
    }

    /// "Nothing came back" and "we never looked" are different failures — one indicts the segmentation,
    /// the other indicts the capture — so the read reports the second as `nil`, never as an empty list.
    func testAnEmptyImageIsNoRowsRatherThanNoCapture() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.16, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let blank = ctx.makeImage()!

        XCTAssertTrue(PopupRowVision.rows(in: blank, popupGlobalPt: CGRect(x: 0, y: 0, width: 200, height: 120)).isEmpty)
        XCTAssertEqual(PopupRowVision.Outcome.notCaptured, .notCaptured)
    }

    // MARK: - Fixtures

    /// A menu-shaped image: one item per row at a constant pitch, optionally with a right-hand shortcut
    /// column, drawn with CoreText so Vision has real glyphs to read (no screen, no TCC).
    private func dropdownImage(items: [String], dark: Bool = false, shortcutOn: String? = nil,
                               shortcut: String = "", width: Int, pitch: CGFloat, fontSize: CGFloat) -> CGImage {
        dropdownImage(rows: items.map { (left: $0, right: $0 == shortcutOn ? shortcut : nil) },
                      dark: dark, width: width, pitch: pitch, fontSize: fontSize)
    }

    /// The same image with a right-hand column per row — a value list ("3840 x 2160" … "Ultra HD") as
    /// well as a shortcut list, which is the shape every custom-drawn dropdown Locator has met takes.
    private func dropdownImage(rows: [(left: String, right: String?)], dark: Bool = false,
                               width: Int, pitch: CGFloat, fontSize: CGFloat) -> CGImage {
        let height = Int(pitch * CGFloat(rows.count) + pitch / 2)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: dark ? 0.16 : 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let fg = dark ? CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
                      : CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: fg] as CFDictionary
        func draw(_ s: String, x: CGFloat, baseline: CGFloat) {
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs)!)
            ctx.textPosition = CGPoint(x: x, y: baseline)   // CoreText baseline is bottom-left
            CTLineDraw(line, ctx)
        }
        for (i, row) in rows.enumerated() {
            let baseline = CGFloat(height) - (pitch * CGFloat(i) + pitch * 0.85)
            draw(row.left, x: 20, baseline: baseline)
            if let right = row.right, !right.isEmpty {
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, right as CFString, attrs)!)
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                draw(right, x: CGFloat(width) - 20 - CGFloat(w), baseline: baseline)
            }
        }
        return ctx.makeImage()!
    }
}

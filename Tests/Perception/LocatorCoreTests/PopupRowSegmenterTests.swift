import XCTest
import CoreGraphics
@testable import LocatorCore

/// ROW PITCH over a pop-up's OCR lines (ticket 07) — the zero-AX half of popup enumeration.
///
/// The failure being pinned: an open dropdown whose app exposes no AX menu (Premiere's format list,
/// DaVinci's resolution list) reached the scene as ONE run-on text blob, so the agent could not name
/// an option. Pure geometry over line boxes; no capture, no OCR, no screen.
final class PopupRowSegmenterTests: XCTestCase {
    private func line(_ t: String, x: CGFloat, y: CGFloat, w: CGFloat = 90, h: CGFloat = 14) -> ElementGrouper.TextRun {
        ElementGrouper.TextRun(rect: CGRect(x: x, y: y, width: w, height: h), text: t)
    }

    /// A list of items at a constant pitch becomes ONE ROW PER ITEM, in reading order.
    func testOneRowPerItem() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 150)
        let names = ["1920x1080", "1280x720", "3840x2160", "720x480", "2048x1080", "4096x2160"]
        let texts = names.enumerated().map { line($1, x: 12, y: 8 + CGFloat($0) * 24) }

        let rows = PopupRowSegmenter.rows(texts, in: popup)

        XCTAssertEqual(rows.map(\.text), names)
    }

    /// Every row's band CONTAINS the glyphs it was named from — hovering the band's middle lands on
    /// that item, which is the whole point of the band (the click target is the row, not the word).
    func testBandContainsItsText() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 150)
        let texts = (0..<6).map { line("item \($0)", x: 12, y: 8 + CGFloat($0) * 24) }

        for row in PopupRowSegmenter.rows(texts, in: popup) {
            XCTAssertTrue(row.rect.insetBy(dx: -0.5, dy: -0.5).contains(row.textRect),
                          "band \(row.rect) does not contain its text \(row.textRect)")
        }
    }

    /// Bands TILE the list: ordered top-to-bottom, never overlapping (an overlap would make two rows
    /// claim the same pixel and the hover-verify would read the wrong item back).
    func testBandsAreOrderedAndDoNotOverlap() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 150)
        let texts = (0..<6).map { line("item \($0)", x: 12, y: 8 + CGFloat($0) * 24) }

        let rows = PopupRowSegmenter.rows(texts, in: popup)

        for (a, b) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThanOrEqual(a.rect.maxY, b.rect.minY + 0.01, "rows overlap: \(a.rect) / \(b.rect)")
        }
    }

    /// A row spans the pop-up's WIDTH (a menu row is the full strip) and never escapes it.
    func testRowsSpanThePopupAndStayInside() {
        let popup = CGRect(x: 400, y: 300, width: 200, height: 150)
        let texts = (0..<5).map { line("item \($0)", x: 412, y: 308 + CGFloat($0) * 24) }

        for row in PopupRowSegmenter.rows(texts, in: popup) {
            XCTAssertGreaterThan(row.rect.width, 0.85 * popup.width, "row \(row.rect) is not strip-wide")
            XCTAssertTrue(popup.insetBy(dx: -0.5, dy: -0.5).contains(row.rect), "row \(row.rect) escaped \(popup)")
        }
    }

    /// A shortcut/value column on the SAME line joins its row ("Copy    ⌘C" is one item, not two) —
    /// the gap is far too wide for `mergeLines`, so row clustering is what has to catch it.
    func testShortcutColumnJoinsItsRow() {
        let popup = CGRect(x: 0, y: 0, width: 300, height: 100)
        let texts = [line("Copy", x: 12, y: 10, w: 50), line("⌘C", x: 240, y: 10, w: 30),
                     line("Paste", x: 12, y: 40, w: 50), line("⌘V", x: 240, y: 40, w: 30)]

        let rows = PopupRowSegmenter.rows(texts, in: popup)

        XCTAssertEqual(rows.map(\.text), ["Copy ⌘C", "Paste ⌘V"])
    }

    /// A state glyph beside the item ("✓ ProRes 422") is geometry, not a name: it must not end up in
    /// the label the agent acts on, and a row that is ONLY such a glyph is not an item at all.
    func testGlyphsNeverNameARow() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 100)
        let texts = [line("✓", x: 6, y: 10, w: 10), line("ProRes 422", x: 30, y: 10),
                     line("H.264", x: 30, y: 40),
                     line("›", x: 6, y: 70, w: 10)]

        let rows = PopupRowSegmenter.rows(texts, in: popup)

        XCTAssertEqual(rows.map(\.text), ["ProRes 422", "H.264"])
    }

    /// A separator's wide gap must not swell the rows around it: the pitch is the MEDIAN spacing, so
    /// one outlier gap changes nothing about how tall a row is.
    func testMedianPitchSurvivesASeparatorGap() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 200)
        let texts = [line("Undo", x: 12, y: 8), line("Redo", x: 12, y: 32), line("Cut", x: 12, y: 56),
                     line("Find", x: 12, y: 123), line("Replace", x: 12, y: 147)]

        let rows = PopupRowSegmenter.rows(texts, in: popup)

        XCTAssertEqual(rows.count, 5)
        for row in rows {
            XCTAssertLessThanOrEqual(row.rect.height, 30, "row \(row.text) swelled to \(row.rect.height)")
        }
        let find = try! XCTUnwrap(rows.first { $0.text == "Find" })
        XCTAssertGreaterThan(find.rect.minY, 100, "the 'Find' band reached up into the separator gap")
    }

    /// A ONE-ITEM pop-up still yields its item (no pitch is computable from a single row — the line
    /// height is the fallback) and the band stays inside the pop-up.
    func testSingleItem() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 40)
        let rows = PopupRowSegmenter.rows([line("Only option", x: 12, y: 13)], in: popup)

        XCTAssertEqual(rows.map(\.text), ["Only option"])
        XCTAssertTrue(popup.insetBy(dx: -0.5, dy: -0.5).contains(rows[0].rect))
        XCTAssertGreaterThan(rows[0].rect.height, 14)
    }

    /// Two items far apart are not two half-screen click targets: the band is bounded by the line
    /// height, so an empty pop-up region never becomes a clickable "row".
    func testBandIsBoundedByTheLineHeight() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 400)
        let rows = PopupRowSegmenter.rows([line("Top", x: 12, y: 10), line("Bottom", x: 12, y: 340)], in: popup)

        XCTAssertEqual(rows.count, 2)
        for row in rows { XCTAssertLessThanOrEqual(row.rect.height, 4 * 14 + 0.01) }
    }

    /// Text that is not in the pop-up (a stray box from a neighbouring window) is not one of its items.
    func testLinesOutsideThePopupAreIgnored() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 100)
        let rows = PopupRowSegmenter.rows([line("inside", x: 12, y: 10), line("outside", x: 12, y: 300)], in: popup)

        XCTAssertEqual(rows.map(\.text), ["inside"])
    }

    func testEmptyInput() {
        XCTAssertTrue(PopupRowSegmenter.rows([], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(PopupRowSegmenter.rows([line("x", x: 0, y: 0)], in: .zero).isEmpty)
    }

    /// A runaway list is capped — the scene must never be flooded by one pop-up.
    func testRowCap() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 8000)
        let texts = (0..<300).map { line("item \($0)", x: 12, y: 8 + CGFloat($0) * 24) }

        XCTAssertEqual(PopupRowSegmenter.rows(texts, in: popup, maxRows: 40).count, 40)
    }
}

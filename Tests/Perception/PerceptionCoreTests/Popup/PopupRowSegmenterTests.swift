//
//  PopupRowSegmenterTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import PerceptionCore
import Testing

/// An open list whose toolkit exposes nothing reached the scene as one run-on blob; these pin the
/// row cut that names each item and gives it a strip to click.
@Suite("Pop-up row segmentation")
struct PopupRowSegmenterTests {

    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 90, h: CGFloat = 14) -> ElementGrouper.TextRun {
        ElementGrouper.TextRun(rect: CGRect(x: x, y: y, width: w, height: h), text: text)
    }

    @Test("one row per item, in reading order")
    func oneRowPerItem() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 150)
        let names = ["1920x1080", "1280x720", "3840x2160", "720x480", "2048x1080", "4096x2160"]
        let texts = names.enumerated().map { line($1, x: 12, y: 8 + CGFloat($0) * 24) }
        #expect(PopupRowSegmenter.rows(texts, in: popup).map(\.text) == names)
    }

    @Test("bands contain their text, tile without overlap, span the pop-up and stay inside it")
    func bandGeometry() {
        let popup = CGRect(x: 400, y: 300, width: 200, height: 150)
        let texts = (0..<5).map { line("item \($0)", x: 412, y: 308 + CGFloat($0) * 24) }
        let rows = PopupRowSegmenter.rows(texts, in: popup)
        for row in rows {
            #expect(row.rect.insetBy(dx: -0.5, dy: -0.5).contains(row.textRect))
            #expect(row.rect.width > 0.85 * popup.width)
            #expect(popup.insetBy(dx: -0.5, dy: -0.5).contains(row.rect))
        }
        for (a, b) in zip(rows, rows.dropFirst()) { #expect(a.rect.maxY <= b.rect.minY + 0.01) }
    }

    @Test("a shortcut column joins its row")
    func shortcutColumnJoins() {
        let popup = CGRect(x: 0, y: 0, width: 300, height: 100)
        let texts = [line("Copy", x: 12, y: 10, w: 50), line("⌘C", x: 240, y: 10, w: 30),
                     line("Paste", x: 12, y: 40, w: 50), line("⌘V", x: 240, y: 40, w: 30)]
        #expect(PopupRowSegmenter.rows(texts, in: popup).map(\.text) == ["Copy ⌘C", "Paste ⌘V"])
    }

    @Test("glyphs never name a row")
    func glyphsNeverName() {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 100)
        let texts = [line("✓", x: 6, y: 10, w: 10), line("ProRes 422", x: 30, y: 10),
                     line("H.264", x: 30, y: 40), line("›", x: 6, y: 70, w: 10)]
        #expect(PopupRowSegmenter.rows(texts, in: popup).map(\.text) == ["ProRes 422", "H.264"])
    }

    @Test("the median pitch survives a separator gap")
    func medianPitch() throws {
        let popup = CGRect(x: 0, y: 0, width: 200, height: 200)
        let texts = [line("Undo", x: 12, y: 8), line("Redo", x: 12, y: 32), line("Cut", x: 12, y: 56),
                     line("Find", x: 12, y: 123), line("Replace", x: 12, y: 147)]
        let rows = PopupRowSegmenter.rows(texts, in: popup)
        #expect(rows.count == 5)
        for row in rows { #expect(row.rect.height <= 30) }
        let find = try #require(rows.first { $0.text == "Find" })
        #expect(find.rect.minY > 100)
    }

    @Test("a single item, a bounded band, lines outside, empty input, and the row cap")
    func edges() {
        let single = PopupRowSegmenter.rows([line("Only option", x: 12, y: 13)], in: CGRect(x: 0, y: 0, width: 200, height: 40))
        #expect(single.map(\.text) == ["Only option"])
        #expect(single.first.map { $0.rect.height > 14 } == true)
        let farApart = PopupRowSegmenter.rows([line("Top", x: 12, y: 10), line("Bottom", x: 12, y: 340)],
                                              in: CGRect(x: 0, y: 0, width: 200, height: 400))
        #expect(farApart.count == 2)
        for row in farApart { #expect(row.rect.height <= 4 * 14 + 0.01) }
        let outside = PopupRowSegmenter.rows([line("inside", x: 12, y: 10), line("outside", x: 12, y: 300)],
                                             in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(outside.map(\.text) == ["inside"])
        #expect(PopupRowSegmenter.rows([], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
        #expect(PopupRowSegmenter.rows([line("x", x: 0, y: 0)], in: .zero).isEmpty)
        let many = (0..<300).map { line("item \($0)", x: 12, y: 8 + CGFloat($0) * 24) }
        #expect(PopupRowSegmenter.rows(many, in: CGRect(x: 0, y: 0, width: 200, height: 8000), maxRows: 40).count == 40)
    }
}

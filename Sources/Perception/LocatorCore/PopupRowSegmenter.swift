import CoreGraphics

/// AN OPEN POP-UP'S ITEMS, CUT OUT OF ITS OWN PIXELS — the zero-AX half of popup enumeration (ticket 07).
///
/// `AXPopupReader` reads a native menu's rows from accessibility and is always preferred: it reports the
/// WHOLE menu, scrolled-out rows included. But a custom-drawn list (Premiere's export format popup,
/// DaVinci's resolution list — Qt/GPU widgets, no AX children at all) exposes nothing to read, and the
/// pop-up then reached the scene as ONE RUN-ON BLOB of text: an agent could see that a list was open and
/// could not name a single option in it.
///
/// This splits the pop-up's OCR LINES into item ROWS by ROW PITCH:
///  • lines that share a baseline band are ONE row — that is how a right-hand shortcut/value column
///    ("Copy    ⌘C") stays with the item it belongs to, a gap far too wide for `mergeLines`;
///  • each row's click BAND is the strip the item occupies, sized by the MEDIAN spacing between rows —
///    so one separator's wide gap cannot swell its neighbours into half-pop-up click targets;
///  • glyph-only fragments (a ✓ state mark, a ›) contribute geometry but never the NAME, because the
///    name is what the agent acts on.
///
/// Pure geometry over line boxes in ONE coordinate space (image px or global pt — every threshold is
/// relative, so the caller picks). No capture, no OCR, no screen: fully offline-testable.
public enum PopupRowSegmenter {
    /// One item of the pop-up, as the eye can see it.
    public struct Row: Sendable, Equatable {
        /// The item's name — the nameworthy fragments of its line(s), left to right.
        public var text: String
        /// The full-width strip the item occupies: the honest hover/click target.
        public var rect: CGRect
        /// The glyphs the name came from — what an overlay draws, and what `rect` must contain.
        public var textRect: CGRect

        public init(text: String, rect: CGRect, textRect: CGRect) {
            self.text = text; self.rect = rect; self.textRect = textRect
        }
    }

    /// Split a pop-up's OCR lines into item rows, top to bottom. `popupPx` is the pop-up's own frame in
    /// the same space as the line rects; `maxRows` keeps one runaway list from flooding a scene.
    public static func rows(_ texts: [ElementGrouper.TextRun], in popupPx: CGRect,
                            maxRows: Int = 240) -> [Row] {
        guard popupPx.width > 1, popupPx.height > 1, maxRows > 0 else { return [] }
        let lines = ElementGrouper.mergeLines(texts)
            .filter { $0.rect.height > 0 && $0.rect.width > 0
                      && popupPx.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY))
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.rect.midY, $0.rect.minX) < ($1.rect.midY, $1.rect.minX) }
        guard !lines.isEmpty else { return [] }

        // ROWS: consecutive lines whose vertical extents genuinely overlap are the same row. Overlap
        // (not "same midY") is what carries a right-hand column whose glyphs sit a pixel or two off the
        // label's baseline, while adjacent rows — whose boxes touch at most at the edges — stay apart.
        var clusters: [[ElementGrouper.TextRun]] = []
        var unions: [CGRect] = []
        for l in lines {
            if let u = unions.last {
                let overlap = min(u.maxY, l.rect.maxY) - max(u.minY, l.rect.minY)
                if overlap >= 0.5 * min(u.height, l.rect.height) {
                    clusters[clusters.count - 1].append(l)
                    unions[unions.count - 1] = u.union(l.rect)
                    continue
                }
            }
            clusters.append([l])
            unions.append(l.rect)
        }

        // PITCH: the MEDIAN gap between row centres — robust to a separator, a section header, or one
        // taller row. Floored at the text height (a band must cover its glyphs) and capped at 4× it, so
        // two items far apart never become two half-pop-up click targets with nothing under them.
        let textHeight = max(1, median(unions.map { Double($0.height) }))
        let centres = unions.map { Double($0.midY) }
        let gaps = zip(centres, centres.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        let measured = gaps.isEmpty ? 1.6 * textHeight : median(gaps)
        let pitch = CGFloat(min(max(measured, 1.15 * textHeight), 4 * textHeight))

        // BANDS: pitch-tall around each row's centre, cut at the midpoint between neighbouring rows so
        // the strips TILE the list, clamped into the pop-up, then grown to cover their own glyphs.
        var bands: [CGRect] = []
        let inset = min(4, popupPx.width * 0.02)
        for (i, u) in unions.enumerated() {
            var top = u.midY - pitch / 2
            var bottom = u.midY + pitch / 2
            if i > 0 { top = max(top, (unions[i - 1].midY + u.midY) / 2) }
            if i + 1 < unions.count { bottom = min(bottom, (u.midY + unions[i + 1].midY) / 2) }
            top = min(max(top, popupPx.minY), u.minY)
            bottom = max(min(bottom, popupPx.maxY), u.maxY)
            bands.append(CGRect(x: popupPx.minX + inset, y: top,
                                width: max(1, popupPx.width - 2 * inset), height: max(1, bottom - top)))
        }
        // Two rows may still claim the same pixel when their glyph boxes themselves overlap (OCR pads
        // tall boxes on a tight list). Split the contested strip down the middle: one pixel, one row.
        for i in bands.indices.dropFirst() where bands[i - 1].maxY > bands[i].minY {
            let top = bands[i - 1].minY, bottom = bands[i].maxY
            guard bottom - top > 2 else { continue }   // nested to the point of nonsense: leave them be
            let seam = min(max((bands[i - 1].maxY + bands[i].minY) / 2, top + 1), bottom - 1)
            bands[i - 1].size.height = seam - top
            bands[i] = CGRect(x: bands[i].minX, y: seam, width: bands[i].width, height: bottom - seam)
        }

        // NAMES: a row is named by its nameworthy fragments only. A ✓ or a › is real (it sized the row)
        // but it is not what the agent asks for, and a row that holds nothing else is not an item.
        var out: [Row] = []
        for (i, cluster) in clusters.enumerated() {
            let name = cluster.sorted { $0.rect.minX < $1.rect.minX }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { ElementGrouper.isNameworthy($0) }
                .joined(separator: " ")
            guard !name.isEmpty else { continue }
            out.append(Row(text: name, rect: bands[i], textRect: unions[i]))
            if out.count == maxRows { break }
        }
        return out
    }

    /// Upper median — the robust middle of a small sample (gaps, heights). Same convention as the
    /// brain's: with an even count it takes the higher of the two middles.
    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        return v.sorted()[v.count / 2]
    }
}

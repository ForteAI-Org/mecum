//
//  PopupRowSegmenter.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// PopupRowSegmenter cuts an open pop-up's items out of its own recognized lines, for a list whose
/// toolkit exposes nothing to accessibility.
///
/// Lines that share a baseline band are one row, which keeps a right-hand shortcut column with the
/// item it belongs to. Each row's click band is sized by the median spacing between rows, so one
/// separator's gap cannot swell its neighbors. Glyph-only fragments (a state mark, a chevron) size
/// a row but never name it, because the name is what an agent acts on. Pure geometry in one
/// coordinate space; every threshold is relative, so the caller picks pixels or points.
public enum PopupRowSegmenter {

    /// One item of the pop-up, as the eye sees it.
    public struct Row: Sendable, Equatable {
        /// The item's name: its nameworthy fragments, left to right.
        public var text: String
        /// The full-width strip the item occupies: the honest hover and click target.
        public var rect: CGRect
        /// The glyphs the name came from, which `rect` always contains.
        public var textRect: CGRect

        public init(text: String, rect: CGRect, textRect: CGRect) {
            self.text     = text
            self.rect     = rect
            self.textRect = textRect
        }
    }

    /// Splits a pop-up's recognized lines into item rows, top to bottom. `popupFrame` is the pop-up's
    /// own frame in the lines' space; `maxRows` keeps one runaway list from flooding a scene.
    public static func rows(_ texts: [ElementGrouper.TextRun], in popupFrame: CGRect, maxRows: Int = 240) -> [Row] {
        guard popupFrame.width > 1, popupFrame.height > 1, maxRows > 0 else { return [] }
        let lines = ElementGrouper.mergeLines(texts)
            .filter {
                $0.rect.height > 0 && $0.rect.width > 0
                    && popupFrame.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY))
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { ($0.rect.midY, $0.rect.minX) < ($1.rect.midY, $1.rect.minX) }
        guard !lines.isEmpty else { return [] }

        var clusters: [[ElementGrouper.TextRun]] = []
        var unions: [CGRect] = []
        for line in lines {
            if let last = unions.last {
                let overlap = min(last.maxY, line.rect.maxY) - max(last.minY, line.rect.minY)
                if overlap >= 0.5 * min(last.height, line.rect.height) {
                    clusters[clusters.count - 1].append(line)
                    unions[unions.count - 1] = last.union(line.rect)
                    continue
                }
            }
            clusters.append([line])
            unions.append(line.rect)
        }

        let textHeight = max(1, median(unions.map { Double($0.height) }))
        let centers = unions.map { Double($0.midY) }
        let gaps = zip(centers, centers.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        let measured = gaps.isEmpty ? 1.6 * textHeight : median(gaps)
        let pitch = CGFloat(min(max(measured, 1.15 * textHeight), 4 * textHeight))

        var bands: [CGRect] = []
        let inset = min(4, popupFrame.width * 0.02)
        for (index, union) in unions.enumerated() {
            var top = union.midY - pitch / 2
            var bottom = union.midY + pitch / 2
            if index > 0 { top = max(top, (unions[index - 1].midY + union.midY) / 2) }
            if index + 1 < unions.count { bottom = min(bottom, (union.midY + unions[index + 1].midY) / 2) }
            top = min(max(top, popupFrame.minY), union.minY)
            bottom = max(min(bottom, popupFrame.maxY), union.maxY)
            bands.append(CGRect(
                x     : popupFrame.minX + inset,
                y     : top,
                width : max(1, popupFrame.width - 2 * inset),
                height: max(1, bottom - top)
            ))
        }
        // Two rows may still claim one pixel when their glyph boxes overlap; split the seam evenly.
        for index in bands.indices.dropFirst() where bands[index - 1].maxY > bands[index].minY {
            let top = bands[index - 1].minY, bottom = bands[index].maxY
            guard bottom - top > 2 else { continue }
            let seam = min(max((bands[index - 1].maxY + bands[index].minY) / 2, top + 1), bottom - 1)
            bands[index - 1].size.height = seam - top
            bands[index] = CGRect(x: bands[index].minX, y: seam, width: bands[index].width, height: bottom - seam)
        }

        var out: [Row] = []
        for (index, cluster) in clusters.enumerated() {
            let name = cluster.sorted { $0.rect.minX < $1.rect.minX }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter(LabelText.isNameworthy)
                .joined(separator: " ")
            guard !name.isEmpty else { continue }
            out.append(Row(text: name, rect: bands[index], textRect: unions[index]))
            if out.count == maxRows { break }
        }
        return out
    }

    /// The upper median of a small sample: with an even count, the higher of the two middles.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}

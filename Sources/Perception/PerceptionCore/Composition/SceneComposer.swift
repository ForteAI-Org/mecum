//
//  SceneComposer.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// SceneComposer turns detected panel rectangles and a flat element list into a structured scene:
/// each panel is named from the header text it contains and from its geometric role, and every
/// element is filed under the smallest panel containing its center.
///
/// Pure geometry and text rules, fully testable offline. It is what turns a four-hundred-element
/// soup into a map a model can reason about.
public enum SceneComposer {

    /// Assigns and names. Returns the elements with `section` set and the panels that hold
    /// something, in reading order; an empty panel is noise, not a map entry.
    public static func compose(
        elements    : [SceneElement],
        sectionRects: [NormalizedRect]
    ) -> ([SceneElement], [SceneSection]) {
        guard !sectionRects.isEmpty else { return (elements, []) }
        let rects = sectionRects.map(\.cgRect)

        // A panel puts its identity at the top: the topmost, then leftmost, nameworthy stable text
        // whose center sits in the panel's top band names it.
        var names: [String?] = []
        for rect in rects {
            let band = max(0.18 * rect.height, 0.02)
            let header = elements
                .filter { element in
                    guard !element.label.isEmpty, !element.isUnlabeled, element.label.count <= 28,
                          LabelText.isNameworthy(element.label), LabelText.isStableLabel(element.label)
                    else { return false }
                    let center = element.bounds.center
                    return rect.contains(center) && center.y <= rect.minY + band
                }
                .min { a, b in a.bounds.y != b.bounds.y ? a.bounds.y < b.bounds.y : a.bounds.x < b.bounds.x }
            names.append(header?.label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A geometric role is the name a person uses; the header stays as a suffix. A bar's identity
        // is its geometry alone.
        for (index, rect) in rects.enumerated() {
            guard let role = role(of: rect) else { continue }
            names[index] = (role == "top bar" || role == "bottom bar")
                ? role
                : (names[index].map { "\(role) (\($0))" } ?? role)
        }
        // A headerless, role-less panel is "region N" in reading order, never a coordinate string.
        var region = 0
        let unnamed = names.indices
            .filter { names[$0] == nil }
            .sorted { (rects[$0].minY, rects[$0].minX) < (rects[$1].minY, rects[$1].minX) }
        for index in unnamed {
            region += 1
            names[index] = "region \(region)"
        }
        var finalNames = names.map { $0 ?? "region ?" }
        var seen: [String: Int] = [:]
        for index in finalNames.indices {
            let name = finalNames[index]
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            if count > 1 { finalNames[index] = "\(name) #\(count)" }
        }

        var out = elements
        var used = Set<Int>()
        for index in out.indices {
            let center = out[index].bounds.center
            var best: Int?
            for (rectIndex, rect) in rects.enumerated() where rect.contains(center) {
                if let current = best, rects[current].width * rects[current].height <= rect.width * rect.height {
                    continue
                }
                best = rectIndex
            }
            if let best {
                out[index].section = finalNames[best]
                used.insert(best)
            }
        }
        let sections = rects.indices
            .filter { used.contains($0) }
            .sorted { (rects[$0].minY, rects[$0].minX) < (rects[$1].minY, rects[$1].minX) }
            .map { SceneSection(name: finalNames[$0], bounds: sectionRects[$0]) }
        return (out, sections)
    }

    /// The geometric role of a panel rectangle, or nil when no coarse shape matches. Every
    /// threshold reads as what a person calls that shape: a full-height sliver on the left is a nav
    /// rail, the narrow column beside it a sidebar, a wide short strip at the top or bottom a bar,
    /// a substantial panel or a wide band of the main column content.
    public static func role(of rect: CGRect) -> String? {
        if rect.minX <= 0.02, rect.maxX <= 0.09 { return "nav rail" }
        if rect.minX <= 0.14, rect.maxX <= 0.34, rect.width <= 0.32 { return "sidebar" }
        if rect.minY <= 0.02, rect.height <= 0.16, rect.width >= 0.5 { return "top bar" }
        if rect.maxY >= 0.97, rect.height <= 0.20, rect.width >= 0.3 { return "bottom bar" }
        if rect.width >= 0.3, rect.height >= 0.25 { return "content" }
        if rect.width >= 0.5, rect.height >= 0.08, rect.minY > 0.02, rect.maxY < 0.98 { return "content" }
        return nil
    }

    /// Coalesces wrapped and stacked prose lines into paragraph elements, inside content-role
    /// panels only. Paragraph line gaps and sidebar row gaps measure alike, so the panel role is the
    /// discriminator. An author-header line ("Name 16:15") breaks a chain so messages never merge.
    public static func coalesceParagraphs(_ elements: [SceneElement]) -> [SceneElement] {
        var mergeable: [String: [Int]] = [:]
        for (index, element) in elements.enumerated()
        where element.kind == .text && !element.isUnlabeled
            && element.section?.hasPrefix("content") == true && !isAuthorHeader(element.label) {
            if let section = element.section { mergeable[section, default: []].append(index) }
        }
        var consumed = Set<Int>()
        var merged: [SceneElement] = []
        for (_, indices) in mergeable {
            let ordered = indices.sorted {
                (elements[$0].bounds.y, elements[$0].bounds.x) < (elements[$1].bounds.y, elements[$1].bounds.x)
            }
            var open: SceneElement?
            var openIndices: [Int] = []
            var lastLine: NormalizedRect?
            func flush() {
                if let paragraph = open, openIndices.count > 1 {
                    merged.append(paragraph)
                    consumed.formUnion(openIndices)
                }
                open = nil
                openIndices = []
            }
            for index in ordered {
                let element = elements[index]
                if let paragraph = open, let last = lastLine {
                    let height = max(last.height, element.bounds.height)
                    let gap = element.bounds.y - last.maxY
                    let sameColumn = abs(element.bounds.x - last.x) <= 1.2 * height
                    let sameSize = max(last.height, element.bounds.height)
                        / max(0.0001, min(last.height, element.bounds.height)) <= 1.5
                    if gap >= -0.2 * height, gap <= 1.35 * height, sameColumn, sameSize,
                       paragraph.label.count + element.label.count <= 240 {
                        var grown = paragraph
                        grown.label = paragraph.label + " " + element.label
                        let minX = min(paragraph.bounds.x, element.bounds.x)
                        let maxX = max(paragraph.bounds.maxX, element.bounds.maxX)
                        grown.bounds = NormalizedRect(
                            x     : minX,
                            y     : paragraph.bounds.y,
                            width : maxX - minX,
                            height: element.bounds.maxY - paragraph.bounds.y
                        )
                        open = grown
                        openIndices.append(index)
                        lastLine = element.bounds
                        continue
                    }
                    flush()
                }
                open = element
                openIndices = [index]
                lastLine = element.bounds
            }
            flush()
        }
        guard !consumed.isEmpty else { return elements }
        var out = elements.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
        out.append(contentsOf: merged)
        return out
    }

    /// True for "Name 16:15": one word of up to 24 characters, a space, then hours and minutes.
    static func isAuthorHeader(_ text: String) -> Bool {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...24).contains(parts[0].count), !parts[0].contains(where: \.isWhitespace) else {
            return false
        }
        let time = parts[1]
        guard let separator = time.firstIndex(where: { $0 == ":" || $0 == "." }) else { return false }
        let hours = time[..<separator], minutes = time[time.index(after: separator)...]
        return (1...2).contains(hours.count) && hours.allSatisfy(\.isNumber)
            && minutes.count == 2 && minutes.allSatisfy(\.isNumber)
    }
}

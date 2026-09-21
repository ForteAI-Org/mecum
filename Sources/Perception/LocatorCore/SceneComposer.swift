import Foundation
import CoreGraphics

/// A named PANEL of the window in a text scene — "TRACKS", "CLIPS", "Busses" — with normalized bounds.
public struct SceneSection: Codable, Equatable, Sendable {
    public var name: String
    public var pos: [Double]                 // [x, y, w, h] window-normalized
    /// VERTICAL scrollability, when known — ledger truth ("scrolls · learned from real scrolls") or
    /// visual evidence ("likely scrolls ↓ — list ends at the edge"). nil = no basis to claim anything.
    /// Sections sit OUTSIDE the scene token, so this never perturbs action guards.
    public var scrolls: String?
    /// SIDEWAYS scrollability ("scrolls → (sideways) · learned"), from the ledger only — no visual
    /// heuristic for horizontal strips exists, and inventing one is how a static pane came to advertise
    /// "scrolls ↓". A SEPARATE field on purpose: every consumer of `scrolls` means the vertical axis
    /// (the scroll verb's candidate list, reach's pane ranking, the sibling ledger's listness test), and
    /// a strip that only slides sideways must not silently walk into those.
    public var scrollsX: String?
    public init(name: String, pos: [Double], scrolls: String? = nil, scrollsX: String? = nil) {
        self.name = name; self.pos = pos; self.scrolls = scrolls; self.scrollsX = scrollsX
    }
}

/// Composes detected section RECTS + scene ELEMENTS into a structured scene: each section is NAMED
/// from the header text it contains, and every element is assigned to its smallest containing section.
/// Pure geometry + text rules — fully offline-testable. This is what turns a 400-element flat soup
/// into a map the LLM can reason about ("the S/M cells inside @DRUM BUSS", "items in the CLIPS list").
public enum SceneComposer {
    /// Assign + name. Returns the elements (with `section` set) and the kept sections (empty ones drop).
    public static func compose(elements: [SceneElement], sectionRects: [[Double]]) -> ([SceneElement], [SceneSection]) {
        let rects = sectionRects.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        guard !rects.isEmpty else { return (elements, []) }

        // NAME each section from its header: the topmost-then-leftmost nameworthy text whose center
        // sits in the section's top band. Panels put their identity at the top ("TRACKS", "CLIPS",
        // "Busses 102", a track strip's name row).
        var names: [String?] = []
        for r in rects {
            let band = max(0.18 * r.height, 0.02)
            let header = elements
                .filter { e in
                    guard e.pos.count == 4, !e.label.isEmpty, e.unlabeled != true,
                          e.label.count <= 28, ElementGrouper.isNameworthy(e.label),
                          SceneDiff.isStableLabel(e.label)   // a timecode/dB readout is a MEASUREMENT, not a name
                    else { return false }
                    let c = CGPoint(x: e.pos[0] + e.pos[2] / 2, y: e.pos[1] + e.pos[3] / 2)
                    return r.contains(c) && c.y <= r.minY + band
                }
                .min { a, b in a.pos[1] != b.pos[1] ? a.pos[1] < b.pos[1] : a.pos[0] < b.pos[0] }
            names.append(header?.label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // ROLE names from geometry: models reason natively in "sidebar / top bar / content" — a route
        // step "click Simone in the sidebar" needs no explanation, while "region 2" (and worse, a name
        // that CHURNS when the window resizes) broke replays (measured on Slack: the sidebar's bottom
        // third landed in a different section than its top). The OCR header stays as a suffix, so
        // "sidebar (Forte AI)" keeps the app's own words too.
        for (i, r) in rects.enumerated() {
            guard let role = Self.role(of: r) else { continue }
            names[i] = names[i].map { "\(role) (\($0))" } ?? role
        }
        // Headerless sections get a plain "region N" (reading order), NOT a coordinate string: an LLM
        // quoted "section@0.50,0.20" as a reach target and got a confusing miss (measured). "region N"
        // still lets describe_section drill in, but never looks like on-screen text to act on.
        var region = 0
        let unnamedOrder = names.indices.filter { names[$0] == nil }
            .sorted { (rects[$0].minY, rects[$0].minX) < (rects[$1].minY, rects[$1].minX) }
        for idx in unnamedOrder { region += 1; names[idx] = "region \(region)" }
        var finalNames = names.map { $0 ?? "region ?" }
        // Duplicate names get ordinals — two "INSERTS" panels must stay distinct.
        var seen: [String: Int] = [:]
        for i in finalNames.indices {
            let n = finalNames[i]
            seen[n, default: 0] += 1
            if seen[n]! > 1 { finalNames[i] = "\(n) #\(seen[n]!)" }
        }
        let names0 = finalNames   // immutable handoff below

        // ASSIGN each element to the SMALLEST section containing its center (sections can nest).
        var out = elements
        var used = Set<Int>()
        for i in out.indices {
            guard out[i].pos.count == 4 else { continue }
            let c = CGPoint(x: out[i].pos[0] + out[i].pos[2] / 2, y: out[i].pos[1] + out[i].pos[3] / 2)
            var best: Int?
            for (si, r) in rects.enumerated() where r.contains(c) {
                if best == nil || r.width * r.height < rects[best!].width * rects[best!].height { best = si }
            }
            if let si = best { out[i].section = names0[si]; used.insert(si) }
        }
        // Keep only sections that hold something — an empty timeline block is noise, not a map entry.
        let sections = rects.indices.filter { used.contains($0) }
            .sorted { (rects[$0].minY, rects[$0].minX) < (rects[$1].minY, rects[$1].minX) }
            .map { SceneSection(name: names0[$0], pos: [rects[$0].minX, rects[$0].minY, rects[$0].width, rects[$0].height]) }
        return (out, sections)
    }

    /// Geometric role of a section rect (window-normalized). Deliberately coarse and app-agnostic —
    /// every threshold reads as "what a human calls that shape": a full-height sliver on the left is
    /// a nav rail, the narrow full-height column beside it a sidebar, a wide short strip pinned to the
    /// top/bottom a bar, the big remainder content. Returns nil when no shape matches (small inner
    /// panels keep their header/region name).
    /// Coalesce WRAPPED/STACKED prose lines into paragraph elements — but ONLY inside content-role
    /// sections. Measured on a live Slack chat: paragraph line gaps (1.0–1.35×h) are indistinguishable
    /// from sidebar ROW gaps (~1.2×h), so geometry alone would blob the DM list into one fake element;
    /// the section ROLE is the discriminator (sidebar/nav/bars never coalesce). Author-header lines
    /// ("Michele 16:15") break the chain so two messages never merge into one.
    public static func coalesceParagraphs(_ elements: [SceneElement]) -> [SceneElement] {
        let headerish = try! NSRegularExpression(pattern: "^\\S{1,24} \\d{1,2}[:.]\\d{2}$")
        func isHeader(_ t: String) -> Bool {
            headerish.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        }
        // Chain PER CONTENT SECTION, over that section's TEXT lines only — the first version chained in
        // global reading order and any interleaved element (an avatar icon, a sidebar row at the same y)
        // flushed the paragraph mid-message (measured: "Domanda…" and its continuation stayed split).
        var mergeable: [String: [Int]] = [:]
        for (i, e) in elements.enumerated()
        where e.kind == "text" && e.unlabeled != true && e.pos.count == 4
            && e.section?.hasPrefix("content") == true && !isHeader(e.label) {
            mergeable[e.section!, default: []].append(i)
        }
        var consumed = Set<Int>()
        var merged: [SceneElement] = []
        for (_, idxs) in mergeable {
            let ordered = idxs.sorted { (elements[$0].pos[1], elements[$0].pos[0]) < (elements[$1].pos[1], elements[$1].pos[0]) }
            var open: SceneElement?
            var openIdxs: [Int] = []
            var lastLine: [Double] = []      // the LAST APPENDED line's pos — gap/size compare against
                                             // the line, not the grown union (a 3-line paragraph's union
                                             // height broke sameSize for every further line; measured)
            func flush() {
                if let o = open { if openIdxs.count > 1 { merged.append(o); consumed.formUnion(openIdxs) } }
                open = nil; openIdxs = []
            }
            for i in ordered {
                let e = elements[i]
                if let o = open, lastLine.count == 4 {
                    let h = max(lastLine[3], e.pos[3])
                    let gap = e.pos[1] - (lastLine[1] + lastLine[3])
                    let sameColumn = abs(e.pos[0] - lastLine[0]) <= 1.2 * h
                    let sameSize = max(lastLine[3], e.pos[3]) / max(0.0001, min(lastLine[3], e.pos[3])) <= 1.5
                    if gap >= -0.2 * h, gap <= 1.35 * h, sameColumn, sameSize,
                       o.label.count + e.label.count <= 240 {
                        var grown = o
                        grown.label = o.label + " " + e.label
                        let maxX = max(o.pos[0] + o.pos[2], e.pos[0] + e.pos[2])
                        grown.pos = [min(o.pos[0], e.pos[0]), o.pos[1],
                                     maxX - min(o.pos[0], e.pos[0]), e.pos[1] + e.pos[3] - o.pos[1]]
                        open = grown
                        openIdxs.append(i)
                        lastLine = e.pos
                        continue
                    }
                    flush()
                }
                open = elements[i]
                openIdxs = [i]
                lastLine = elements[i].pos
            }
            flush()
        }
        guard !consumed.isEmpty else { return elements }
        var out = elements.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
        out.append(contentsOf: merged)
        return out
    }

    public static func role(of r: CGRect) -> String? {
        // X-SPAN based, not full-height: the detector returns LEAVES, so a sidebar that subdivides
        // into header/list/selected-row must still name every fragment "sidebar …" — the fragment's
        // column membership is what the model needs ("Simone in the sidebar"), not its exact band.
        if r.minX <= 0.02, r.maxX <= 0.09 { return "nav rail" }
        if r.minX <= 0.14, r.maxX <= 0.34, r.width <= 0.32 { return "sidebar" }
        if r.minY <= 0.02, r.height <= 0.16, r.width >= 0.5 { return "top bar" }
        // No minX floor: a bottom bar can span the full window (Premiere's Export strip) or just the
        // content column (Slack's composer). Width ≥ 0.3 keeps sidebar bottom-fragments out.
        if r.maxY >= 0.97, r.height <= 0.20, r.width >= 0.3 { return "bottom bar" }
        // Two content shapes: a substantial PANEL (Premiere's settings/preview columns, ≥0.3 wide and
        // tall) or a wide BAND of the main column (Slack's message bands — thin but ≥half the window).
        // Narrow thin strips (settings rows at 0.36×0.09) stay "region N" — they are rows, not panels.
        if r.width >= 0.3, r.height >= 0.25 { return "content" }
        if r.width >= 0.5, r.height >= 0.08, r.minY > 0.02, r.maxY < 0.98 { return "content" }
        return nil
    }
}

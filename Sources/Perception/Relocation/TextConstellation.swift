import CoreGraphics
import Foundation
import LocatorCore

/// Pure text-constellation matching for stage 3b: locate an element by finding its self-text and
/// verifying the surrounding text neighbors sit at their expected relative offsets. Decoupled from
/// Vision (`runs` are plain (text, box) pairs) so it's fully unit-testable.
public enum TextConstellation {

    /// STRICT identity match for disambiguating near-identical labels ("Audio 5" vs "Audio 6"):
    /// normalized equality or very-high similarity (≥ 0.9). Unlike ``matches``, a single-character
    /// difference in a SHORT label fails on purpose — for a repeating list the differing digit *is* the
    /// identity. (Long labels stay tolerant of one OCR slip: 1 edit in 14 chars is still ≥ 0.9.)
    public static func identityMatches(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb || similarity(na, nb) >= 0.9
    }

    /// Fuzzy match tolerant of OCR noise ("Audi1" ≈ "Audio 1"): normalized equality, substring, or
    /// edit-distance similarity ≥ 0.7.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        if na.count >= 3, (na.contains(nb) || nb.contains(na)) { return true }
        return similarity(na, nb) >= 0.7
    }

    /// Best element box: the self-text run whose neighbors most agree with the stored constellation.
    /// `offsetScale` rescales stored (capture-px) offsets to the current window; `tolerancePadPx` adds
    /// slack on top of each neighbor's tolerance.
    public static func locate(
        selfText: String, neighbors: [TextNeighbor], offsetScale: CGFloat, tolerancePadPx: CGFloat,
        runs: [(text: String, box: CGRect)]
    ) -> (box: CGRect, neighborFraction: Double)? {
        // IDENTITY match (digit-sensitive), not loose fuzzy: for a near-identical list ("Audio 4" …
        // "Audio 8") fuzzy would conflate siblings, so "Audio 4" must match only "Audio 4". If the exact
        // target isn't on screen (e.g. scrolled out of view) there are NO candidates → nil (honest miss),
        // rather than clicking a look-alike.
        let candidates = runs.filter { identityMatches(selfText, $0.text) }
        guard !candidates.isEmpty else { return nil }
        let normSelf = normalize(selfText)

        // Rank by neighbor agreement first; break ties by preferring an EXACT (normalized-equal) run, so
        // a duplicate like "Audio 1" isn't resolved to "Audio 11"/"Audio 12" by substring containment —
        // while a fuzzy run with strong neighbor support still beats an exact-but-isolated decoy.
        var best: (box: CGRect, frac: Double, exact: Bool)?
        for candidate in candidates {
            let origin = candidate.box.origin
            let found = neighbors.filter { nb in
                let expected = CGPoint(x: origin.x + nb.offset.x * offsetScale, y: origin.y + nb.offset.y * offsetScale)
                let tolerance = nb.tolerancePx * offsetScale + tolerancePadPx
                return runs.contains { run in
                    identityMatches(nb.text, run.text)
                        && hypot(run.box.minX - expected.x, run.box.minY - expected.y) <= tolerance
                }
            }.count
            let frac = neighbors.isEmpty ? 1.0 : Double(found) / Double(neighbors.count)
            let exact = normalize(candidate.text) == normSelf
            let better: Bool = {
                guard let b = best else { return true }
                if frac != b.frac { return frac > b.frac }
                return exact && !b.exact
            }()
            if better { best = (candidate.box, frac, exact) }
        }
        return best.map { ($0.box, $0.frac) }
    }

    /// Neighbor-anchored location for when the element's OWN text/appearance changed (e.g. a dropdown
    /// whose VALUE was edited, so its self-text no longer matches): triangulate the element origin from
    /// the STABLE surrounding labels. Each found neighbor implies an element origin (its found position
    /// minus the stored relative offset); the origin where the most DISTINCT neighbors agree wins.
    /// Requires `minAgree` distinct neighbors so a single ambiguous label can't mislocate.
    public static func locateByNeighbors(
        neighbors: [TextNeighbor], offsetScale: CGFloat, tolerancePadPx: CGFloat,
        elementSizePx: CGSize, minAgree: Int, runs: [(text: String, box: CGRect)]
    ) -> (box: CGRect, anchorFraction: Double)? {
        guard !neighbors.isEmpty else { return nil }
        // Each (neighbor index, implied element origin) is a vote. DISCRIMINATING neighbours only: a
        // label that recurs on many rows ("wave"/"S"/"M" on every track) matches everywhere and would
        // let ANY row form a false cluster — skip a neighbour that matches more than `genericLimit` runs.
        let genericLimit = 3
        var votes: [(idx: Int, origin: CGPoint)] = []
        for (i, nb) in neighbors.enumerated() {
            let matching = runs.filter { identityMatches(nb.text, $0.text) }
            guard matching.count <= genericLimit else { continue }
            for run in matching {
                votes.append((i, CGPoint(x: run.box.minX - nb.offset.x * offsetScale,
                                         y: run.box.minY - nb.offset.y * offsetScale)))
            }
        }
        guard !votes.isEmpty else { return nil }

        let clusterTol = tolerancePadPx + 16 * offsetScale
        var best: (origin: CGPoint, distinct: Int, spread: CGFloat)?
        for v in votes {
            let agreeing = votes.filter { hypot($0.origin.x - v.origin.x, $0.origin.y - v.origin.y) <= clusterTol }
            // Score and centroid both dedup by neighbor index: take ONE representative per distinct
            // neighbor (its vote closest to v) so a single label matching many runs can't inflate the
            // count or drag the centroid off the true origin.
            var repByIdx: [Int: CGPoint] = [:]
            for vote in agreeing {
                let d = hypot(vote.origin.x - v.origin.x, vote.origin.y - v.origin.y)
                if let cur = repByIdx[vote.idx] {
                    if d < hypot(cur.x - v.origin.x, cur.y - v.origin.y) { repByIdx[vote.idx] = vote.origin }
                } else { repByIdx[vote.idx] = vote.origin }
            }
            let reps = Array(repByIdx.values)
            let distinct = reps.count
            let cx = reps.reduce(0) { $0 + $1.x } / CGFloat(distinct)
            let cy = reps.reduce(0) { $0 + $1.y } / CGFloat(distinct)
            let center = CGPoint(x: cx, y: cy)
            let spread = reps.reduce(0) { $0 + hypot($1.x - center.x, $1.y - center.y) } / CGFloat(distinct)
            // Prefer more distinct agreeing neighbors; on a tie, the tighter cluster — never vote order.
            let better: Bool = {
                guard let b = best else { return true }
                if distinct != b.distinct { return distinct > b.distinct }
                return spread < b.spread
            }()
            if better { best = (center, distinct, spread) }
        }
        guard let best, best.distinct >= minAgree else { return nil }
        return (CGRect(origin: best.origin, size: elementSizePx), Double(best.distinct) / Double(neighbors.count))
    }

    /// Does a GLOBALLY-UNIQUE recorded neighbor — one whose text matches EXACTLY ONE run in the current
    /// frame — sit at its expected offset from `box`? This is the trust gate for a neighbor-anchored hit
    /// on a near-identical list. The per-row-repeating layout ("wave"/"S"/"M" on every track) clusters
    /// identically on EVERY row, so an anchor built only from it may have triangulated the WRONG instance
    /// (the observed "Audio 3" off-screen → clicked the "Audio 28" row). A neighbor that is unique in the
    /// frame (an adjacent track number that IS visible, or a dropdown's unique field label) pins the
    /// absolute position; if none is present at its expected place, the anchor is not trustworthy.
    public static func hasUniqueNeighborSupport(
        box: CGRect, neighbors: [TextNeighbor], offsetScale: CGFloat, tolerancePadPx: CGFloat,
        runs: [(text: String, box: CGRect)]
    ) -> Bool {
        for nb in neighbors {
            let matching = runs.filter { identityMatches(nb.text, $0.text) }
            guard matching.count == 1 else { continue }   // unique in this frame
            let expected = CGPoint(x: box.minX + nb.offset.x * offsetScale, y: box.minY + nb.offset.y * offsetScale)
            let tol = nb.tolerancePx * offsetScale + tolerancePadPx
            if hypot(matching[0].box.minX - expected.x, matching[0].box.minY - expected.y) <= tol { return true }
        }
        return false
    }

    // MARK: Internals

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let distance = editDistance(Array(a), Array(b))
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : 1 + min(prev[j], cur[j - 1], prev[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

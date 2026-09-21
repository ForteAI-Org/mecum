import Foundation
import CoreGraphics

/// VISUAL evidence that a section scrolls — inferred from geometry alone, before anyone has ever
/// scrolled it. The seed observation (Ron's): *a section is likely scrollable when it holds a LIST of
/// elements and the last one sits very near the section's edge* — a complete list ends with slack; a
/// viewport onto a longer list is cut mid-flow.
///
/// This is the cold-start complement to the living memory's `scroll_pane` table (ground truth from real
/// scrolls, user's or the engine's). Truth always outranks inference; evidence fills the silence. One
/// pure scorer, consumed three ways: the scene map tells the LLM what likely scrolls, reach ranks its
/// candidate panes and seeds its direction, the watcher decides which sections deserve sibling-ledger
/// recording.
public struct ScrollEvidence: Codable, Equatable, Sendable {
    /// Aligned, regularly-pitched member rows found (0 = no list structure).
    public var listRows: Int
    /// Median vertical pitch between consecutive rows, in the same normalized space as the inputs.
    public var rowPitch: Double?
    /// The last row runs into (or is clipped by) the section's bottom edge — content likely continues below.
    public var moreBelow: Bool
    /// Same at the top — content likely continues above (i.e. the pane is scrolled down already).
    public var moreAbove: Bool
    /// The verdict: this section is probably a vertical-scroll viewport.
    public var likelyScrollsV: Bool
    /// Honest one-line justification for logs and the memory visualizer.
    public var why: String

    public static let none = ScrollEvidence(listRows: 0, rowPitch: nil, moreBelow: false,
                                            moreAbove: false, likelyScrollsV: false, why: "no list structure")
}

public enum ScrollScout {
    /// Tunables — measured on the CVAT benchmark screenshots (Keynote / task10 / Resolve overlays via
    /// `debug-segment --scroll`), not invented. Every length is relative to the section itself, so the
    /// scorer is scale-free: window-normalized rects (scene path) and pixel rects (reach path) score
    /// identically.
    public struct Params: Sendable {
        /// Rows count as one aligned column when their left edges sit within this FRACTION OF THE
        /// SECTION'S WIDTH of the column median. (The sibling ledger's 0.03-of-window on a ~0.2-wide
        /// sidebar was ~0.15 of the section; 0.12 is that, slightly tightened.)
        public var alignTolerance: Double = 0.12
        /// Minimum aligned rows before "list" means anything. Below 4 the pitch median is noise.
        public var minRows: Int = 4
        /// Pitch regularity: median absolute deviation of consecutive gaps must stay within this
        /// fraction of the median pitch. Real lists measure well under this; forms and settings panes
        /// blow past it.
        public var pitchSpreadMax: Double = 0.35
        /// Bottom truncation: the last row's bottom is within (fraction × pitch) of the section bottom —
        /// or past it (clipped). A complete list ends with at least a row's worth of slack.
        public var edgeFraction: Double = 0.75
        /// Top truncation is judged MUCH stricter than bottom: every list starts near the top of its
        /// pane, so ordinary padding must not read as "scrolled down". Only a clipped first row or a
        /// near-zero gap counts.
        public var topEdgeFraction: Double = 0.25
        /// Fill: rows must occupy at least this fraction of the section's height for a *fill-based*
        /// scrollability call (a short complete list floating in a tall panel is NOT a viewport).
        public var fillMin: Double = 0.82
        /// ANY verdict (edge- or fill-based) needs at least this many rows; an edge call additionally
        /// needs `fillMinForEdgeCall`. Both measured on the benchmark: Media Composer's monitor pane (4
        /// sparse chrome rows near a cut) and two 4-row button stacks read as "scrolls" without them.
        /// Sparse chrome and short dense stacks are not lists. 4 rows still REPORT structure — they just
        /// never carry a verdict alone.
        public var minRowsForCall: Int = 5
        public var fillMinForEdgeCall: Double = 0.5
        /// RUN continuity: a neighbouring pane's row counts as CARRYING ON this list when it sits
        /// within this many row pitches of the boundary row. A list's own inter-row gap is under one
        /// pitch by construction, so 1.0 accepts "the very next row" and nothing looser.
        public var runContinuation: Double = 1.0
        /// Two panes ABUT when their shared edge coincides within this fraction of the shorter pane's
        /// height (the X-Y cut leaves exact edges; the slack is for rounding through normalization)…
        public var runAbut: Double = 0.02
        /// …and overlap horizontally by at least this fraction of the narrower one — a run is ONE
        /// column cut into tiles, never a pane sitting beside another.
        public var runColumnOverlap: Double = 0.6
        public init() {}
    }

    /// One pane as the run walker sees it: its rect, its members, and its FAMILY — the canonical
    /// section role ("sidebar", "content"). Callers without names (the reach path ranks bare rects)
    /// pass nil and let geometry alone decide.
    public struct Pane: Sendable {
        public var rect: CGRect
        public var members: [CGRect]
        public var family: String?
        public init(rect: CGRect, members: [CGRect], family: String? = nil) {
            self.rect = rect; self.members = members; self.family = family
        }
    }

    /// The aligned ROW BAND of a set of members — the first half of every assessment, extracted so the
    /// run walker can ask "does this list carry on into the pane next door?" with the same geometry the
    /// verdict is made from.
    struct RowBand {
        var rows: [CGRect]
        var pitch: CGFloat
        var regular: Bool
        var left: CGFloat, right: CGFloat, mid: CGFloat   // column medians: lists align L, R or centre
        var tol: CGFloat

        /// Is `r` the next row of this list — same column, one pitch on, in the given direction?
        /// (`rows` is non-empty by construction: rowBand only returns with at least `minRows`.)
        func continues(_ r: CGRect, below: Bool, within: Double) -> Bool {
            let sameColumn = abs(r.minX - left) <= tol || abs(r.maxX - right) <= tol || abs(r.midX - mid) <= tol
            guard sameColumn, let first = rows.first, let last = rows.last else { return false }
            let gap = below ? r.minY - last.maxY : first.minY - r.maxY
            return gap <= CGFloat(within) * pitch && gap >= -0.25 * pitch
        }
    }

    static func rowBand(sectionRect: CGRect, memberRects: [CGRect], params: Params) -> RowBand? {
        guard sectionRect.height > 0, sectionRect.width > 0 else { return nil }
        // Members that actually live in the section (callers usually pre-filter; be tolerant anyway).
        let inside = memberRects.filter { sectionRect.intersects($0) && $0.height > 0 }
        guard inside.count >= params.minRows else { return nil }

        // ONE aligned column: cluster by left edge around the median. Lists align left; toolbars and
        // free-floating controls don't. (A grid/table still yields its first column — fine: a grid that
        // fills to the edge scrolls too.)
        let xs = inside.map(\.minX).sorted()
        let xMed = xs[xs.count / 2]
        let alignTol = params.alignTolerance * sectionRect.width
        let aligned = inside.filter { abs($0.minX - xMed) <= alignTol }
            .sorted { $0.minY < $1.minY }
        guard aligned.count >= params.minRows else { return nil }

        // De-duplicate rows that share a line (an icon and its text both aligned): keep one rect per
        // vertical band, unioned — pitch must measure ROW distance, not intra-row fragments.
        var rows: [CGRect] = []
        for r in aligned {
            if let last = rows.last, r.minY < last.maxY - min(last.height, r.height) * 0.5 {
                rows[rows.count - 1] = last.union(r)
            } else {
                rows.append(r)
            }
        }
        guard rows.count >= params.minRows else { return nil }

        // Pitch: median of consecutive top-to-top gaps, spread-checked.
        let gaps = zip(rows.dropFirst(), rows).map { $0.minY - $1.minY }.filter { $0 > 0 }
        guard gaps.count >= params.minRows - 1 else { return nil }
        let sortedGaps = gaps.sorted()
        let pitch = sortedGaps[sortedGaps.count / 2]
        guard pitch > 0 else { return nil }
        let deviations = gaps.map { abs($0 - pitch) }.sorted()
        let med: ((CGRect) -> CGFloat) -> CGFloat = { f in
            let v = rows.map(f).sorted(); return v[v.count / 2]
        }
        return RowBand(rows: rows, pitch: pitch,
                       regular: deviations[deviations.count / 2] <= params.pitchSpreadMax * pitch,
                       left: xMed, right: med(\.maxX), mid: med(\.midX), tol: alignTol)
    }

    /// The RUN a pane belongs to: itself plus every abutting sibling the list VISIBLY CARRIES ON INTO —
    /// same column (left-, right- or centre-aligned; DaVinci's category list is right-aligned), the very
    /// next row one pitch on. The section cut is a mosaic, so a list sliced across two tiles is ONE
    /// viewport and its boundary is an artifact, not an edge. Measured: without this, the invented seam
    /// in DaVinci's Project Settings carried the full truncation signature and the map advertised
    /// "scrolls ↓ (more below)" on a pane nothing can scroll (and the lie got learned); and a Finder
    /// sidebar whose real truncation lands in a 0.08-tall bottom tile keeps its honest claim, which
    /// silencing the seam alone would have thrown away. Every pane of a run reports the run's verdict —
    /// the scroll verb already treats mosaic tiles of one column as one pane.
    public static func assess(paneAt i: Int, in panes: [Pane], params: Params = Params()) -> ScrollEvidence {
        guard panes.indices.contains(i), panes[i].rect.width > 0, panes[i].rect.height > 0 else { return .none }
        let family = panes[i].family
        var run: Set<Int> = [i]
        var rect = panes[i].rect
        var members = panes[i].members
        // Grow while the band's list runs on into a neighbour; each merge can expose the next tile.
        for _ in panes.indices {
            guard let band = rowBand(sectionRect: rect, memberRects: members, params: params) else { break }
            var merged = false
            for (j, other) in panes.enumerated() where !run.contains(j) {
                guard other.rect.width > 0, other.rect.height > 0, other.family == family else { continue }
                let overlap = min(rect.maxX, other.rect.maxX) - max(rect.minX, other.rect.minX)
                guard overlap >= params.runColumnOverlap * min(rect.width, other.rect.width) else { continue }
                let tol = params.runAbut * min(rect.height, other.rect.height)
                let below = abs(other.rect.minY - rect.maxY) <= tol
                let above = abs(other.rect.maxY - rect.minY) <= tol
                guard below || above else { continue }
                guard other.members.contains(where: {
                    band.continues($0, below: below, within: params.runContinuation)
                }) else { continue }
                run.insert(j); rect = rect.union(other.rect); members += other.members; merged = true
            }
            if !merged { break }
        }
        let e = assess(sectionRect: rect, memberRects: members, params: params)
        guard run.count > 1, e.listRows > 0 else { return e }
        var out = e
        out.why += " (across \(run.count) stacked panes — one list, cut by the section detector)"
        return out
    }

    /// Assess ONE section rect in isolation. `sectionRect` and `memberRects` share ONE coordinate space
    /// (window-normalized in the scene path; image pixels in the reach path — the math is scale-free,
    /// only alignTolerance assumes window-normalized x, so pixel callers pass tolerance × imageWidth via
    /// `params`). Callers holding the whole section cut should use `assess(paneAt:in:)` instead: a
    /// section boundary the list runs straight through is a mosaic artifact, and judging one tile of it
    /// alone is how a static pane came to advertise "scrolls ↓".
    public static func assess(sectionRect: CGRect, memberRects: [CGRect],
                              params: Params = Params()) -> ScrollEvidence {
        guard let band = rowBand(sectionRect: sectionRect, memberRects: memberRects, params: params)
        else { return .none }
        let rows = band.rows, pitch = band.pitch
        // Fill is computed either way — a variable-row-height list (a messages pane) is pitch-IRREGULAR
        // yet still a viewport when its rows pack the section, so irregularity only disables the
        // pitch-based EDGE cues, not the call.
        let bandHeight = (rows.last?.maxY ?? 0) - (rows.first?.minY ?? 0)
        let fill = bandHeight / sectionRect.height

        guard band.regular else {
            let dense = fill >= params.fillMin && rows.count >= params.minRowsForCall
            return ScrollEvidence(listRows: rows.count, rowPitch: nil, moreBelow: false, moreAbove: false,
                                  likelyScrollsV: dense,
                                  why: dense ? "irregular rows but they pack \(Int(fill * 100))% of the section"
                                             : "rows but irregular pitch — a form, not a list")
        }

        // The edge cues, in row pitches — the natural unit of a list. Bottom: near OR clipped. Top:
        // STRICT — a clipped first row, or a near-zero gap; ordinary top padding is how every list
        // starts and must never read as "scrolled down".
        let bottomGap = sectionRect.maxY - (rows.last?.maxY ?? sectionRect.maxY)
        let topGap = (rows.first?.minY ?? sectionRect.minY) - sectionRect.minY
        let moreBelow = bottomGap <= params.edgeFraction * pitch
        let moreAbove = topGap <= params.topEdgeFraction * pitch

        // A cue only VERDICTS with real list mass behind it (enough rows; for edge cues, a band that
        // fills the section) — a few chrome rows drifting near a cut are not a viewport. The direction
        // flags stay raw: even a non-verdict's hints can seed a scroll direction elsewhere.
        let enoughRows = rows.count >= params.minRowsForCall
        let edgeCall = (moreBelow || moreAbove) && enoughRows && fill >= params.fillMinForEdgeCall
        let likely = edgeCall || (enoughRows && fill >= params.fillMin)
        let clipped = bottomGap < 0
        let why: String
        if edgeCall, moreBelow, moreAbove { why = "list of \(rows.count) runs edge to edge" }
        else if edgeCall, moreBelow {
            why = clipped ? "list of \(rows.count), last row CLIPPED by the bottom edge"
                          : "list of \(rows.count) ends at the bottom edge (gap \(round2(bottomGap / pitch)) rows)"
        }
        else if edgeCall { why = "list of \(rows.count) is flush with the top edge (scrolled down)" }
        else if likely { why = "list of \(rows.count) fills \(Int(fill * 100))% of the section" }
        else if moreBelow || moreAbove { why = "\(rows.count) rows near an edge but sparse (fill \(Int(fill * 100))%) — not called" }
        else { why = "complete list of \(rows.count) (slack \(round2(bottomGap / pitch)) rows below)" }
        return ScrollEvidence(listRows: rows.count, rowPitch: pitch,
                              moreBelow: moreBelow, moreAbove: moreAbove,
                              likelyScrollsV: likely, why: why)
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/// User-gesture scroll CALIBRATION: two scenes around one wheel gesture → pixels the pane's content
/// moved per line-unit delivered, or nil when the evidence is thin. The watcher records the result as
/// a px-per-tick HINT (fills a missing calibration, never overwrites the engine's NCC-measured one).
public enum UserScrollCalibration {
    /// WHICH WAY a pane's rows actually went, as the signed median Δy in window-normalized units:
    /// POSITIVE = the rows moved DOWN the window, so the view revealed what was ABOVE them — the view
    /// scrolled UP. Negative = the view went down. nil when the evidence is thin.
    ///
    /// Named elements are the one direction witness that periodicity cannot fool. The pixel witness
    /// (`ScrollProbe.contentSlidePx`) aligns a brightness profile, and a document's text lines or a file
    /// list's rows are EVENLY SPACED — measured on real captures, the alignment fits the mirrored lag
    /// almost as well as the true one (ratios 1.04–1.34), so its sign is a coin toss on exactly the
    /// surfaces people scroll most. Labels are unique: "Applications" moved from y 0.31 to y 0.44, and
    /// there is nothing ambiguous about that. This is what teaches `WheelPolarity` which sign the wheel
    /// needs; the pixels remain the fallback for panes with no labels at all (an opaque canvas).
    ///
    /// Rigid-shift discipline (unchanged, and the reason this is trustworthy): same element id, x
    /// unchanged within a hair (a real scroll moves things VERTICALLY; x drift means a resize or
    /// relayout, which teaches nothing), ≥3 matches that AGREE on one shift.
    public static func rigidShift(prev: SceneSnapshot, now: SceneSnapshot, section: String) -> Double? {
        let family = String(section.prefix(while: { $0 != "(" })).trimmingCharacters(in: .whitespaces)
        let inFamily: (SceneElement) -> Bool = { e in
            guard let s = e.section else { return false }
            return family.isEmpty ? s == section : s.hasPrefix(family)
        }
        // UNIQUE identities only, on BOTH sides. A file list is full of repeats — "4 KB" three times,
        // the same date on six rows — and pairing the first "4 KB" of one frame with the first of the
        // next pairs DIFFERENT ROWS, which yields a confident shift in whichever direction the repeats
        // happen to lie. Measured on Finder's Downloads: that is how a list that had just scrolled DOWN
        // read as having gone up, and taught the wheel the wrong sign. A name that occurs once in each
        // frame is the same thing in both, and nothing else is.
        let prevRows = prev.elements.filter { inFamily($0) && $0.pos.count == 4 }
        let nowRows = now.elements.filter { inFamily($0) && $0.pos.count == 4 }
        return rigidShift(prevRows: prevRows, nowRows: nowRows)
    }

    /// A selected pane in the same window survives changing header labels. Live TextEdit's row-057
    /// header became row-038 after a nudge; filtering by the old section name discarded all witnesses.
    /// Keep the existing unique-row / rigid-motion gates, scoped to the pane's observed geometry.
    public static func rigidShift(prev: SceneSnapshot, now: SceneSnapshot, within pane: CGRect) -> Double? {
        guard prev.bundleID == now.bundleID, prev.windowTitle == now.windowTitle,
              prev.viewportPx == now.viewportPx else { return nil }
        func inside(_ e: SceneElement) -> Bool {
            guard e.pos.count == 4, e.pos.allSatisfy({ $0.isFinite }), e.pos[2] > 0, e.pos[3] > 0 else { return false }
            return pane.contains(CGPoint(x: e.pos[0] + e.pos[2] / 2, y: e.pos[1] + e.pos[3] / 2))
        }
        return rigidShift(prevRows: prev.elements.filter(inside), nowRows: now.elements.filter(inside))
    }

    private static func rigidShift(prevRows: [SceneElement], nowRows: [SceneElement]) -> Double? {
        let onceInPrev = Set(Dictionary(grouping: prevRows, by: \.id).filter { $0.value.count == 1 }.keys)
        let onceInNow = Set(Dictionary(grouping: nowRows, by: \.id).filter { $0.value.count == 1 }.keys)
        let unique = onceInPrev.intersection(onceInNow)
        let before = Dictionary(prevRows.filter { unique.contains($0.id) }.map { ($0.id, $0) },
                                uniquingKeysWith: { a, _ in a })
        var dys: [Double] = []
        for e in nowRows where unique.contains(e.id) {
            guard let b = before[e.id], abs(e.pos[0] - b.pos[0]) < 0.01 else { continue }
            let dy = e.pos[1] - b.pos[1]
            if abs(dy) > 0.004 { dys.append(dy) }   // sub-noise moves teach nothing
        }
        guard dys.count >= 3 else { return nil }
        let median = dys.sorted()[dys.count / 2]
        guard dys.filter({ abs($0 - median) < 0.01 }).count >= 3 else { return nil }
        return median
    }

    /// The px-per-wheel-unit sample the watcher feeds the living memory: `rigidShift`'s MAGNITUDE over
    /// the units delivered. Direction is a separate question with a separate answer (`rigidShift`) —
    /// keeping the two apart is what stopped a wheel sign from being learned as `abs`.
    public static func sample(prev: SceneSnapshot, now: SceneSnapshot,
                              section: String, wheelUnits: Int) -> Double? {
        guard wheelUnits >= 3, now.viewportPx.count == 2,
              let shift = rigidShift(prev: prev, now: now, section: section) else { return nil }
        let sample = abs(shift) * Double(now.viewportPx[1]) / Double(wheelUnits)
        return (0.5...300).contains(sample) ? sample : nil
    }
}

/// Fuses ledger TRUTH with ScrollScout INFERENCE into the one line a section shows the LLM.
public enum ScrollAnnotator {
    /// - `learned`: the living memory's verdict from REAL scrolls (user's or the engine's), nil if the
    ///   pane was never scrolled. Truth always outranks inference; a learned "doesn't scroll" silences
    ///   even strong visual evidence (no claim beats a wrong claim).
    public static func annotate(learned: Bool?, evidence: ScrollEvidence) -> String? {
        if learned == true { return "scrolls\(arrow(evidence)) · learned" }
        if learned == false { return nil }
        guard evidence.likelyScrollsV else { return nil }
        return "likely scrolls\(arrow(evidence)) — \(evidence.why)"
    }

    /// The SIDEWAYS claim — a separate verdict on a separate axis, and ledger-only. There is no visual
    /// evidence path here on purpose: a horizontal strip's cues (a card clipped by the right edge) are
    /// the same shapes ordinary layout makes, and the vertical scorer's own history says an invented cue
    /// becomes an advertised lie. So the map speaks about the sideways axis exactly when something
    /// really slid sideways there — DaVinci's Deliver preset carousel, after one successful
    /// `scroll(direction:"right")`.
    /// - `learned`: the ledger's `axis:"h"` verdict for this pane's role, nil if never proven.
    public static func annotateSideways(learned: Bool?) -> String? {
        learned == true ? "scrolls → (sideways) · learned" : nil
    }

    /// The WRITE half of that claim: WHICH pane a horizontal burst just moved, i.e. the role to record
    /// as `axis:"h"`. The verb path needs no such function — it wheels a named section at its centre, so
    /// the pane is the section the caller asked for. reach's AX-DIRECTED path is the one that does: it
    /// wheels a BAND of an AX container (measured: the carousel's only AX ancestor is the whole 449×754
    /// render-settings panel, so the band crosses the static settings form too), and until this existed
    /// that path scrolled panes sideways and the ledger learned nothing — 61 vertical rows, zero
    /// horizontal ones, on the machine that has driven the Deliver carousel across four tickets.
    ///
    /// Named from the LABELS, not from geometry: the elements that ARRIVED in the band belong to the pane
    /// whose content moved, whatever else the band happens to overlap. A pane's own share of the band is
    /// no evidence at all — the form's rows outnumber the strip's items and the form did not move.
    ///
    /// POSITIVE ONLY, like the verb path's writer: an unchanged band is genuinely ambiguous between "this
    /// pane doesn't scroll" and "it is at its end", and since nothing infers a sideways affordance, a
    /// recorded `false` could only ever erase a truth an earlier real scroll proved.
    /// - `bandBefore`: the band's labels BEFORE the burst — nil when the caller never measured one, which
    ///   is not the same as an empty band and must not read as "everything here is new".
    /// - `bandNow`: the elements inside the band in the scene just parsed.
    /// - Returns: the section name to record, or nil — no witness, no name, or no majority.
    public static func sidewaysPaneToLearn(bandBefore: Set<String>?, bandNow: [SceneElement]) -> String? {
        guard let bandBefore else { return nil }
        guard Set(bandNow.map(\.label)) != bandBefore else { return nil }   // nothing moved
        // The ARRIVALS decide; if items only left the band (the last screenful of a carousel), what
        // remains in it still belongs to the pane that slid.
        let arrived = bandNow.filter { !bandBefore.contains($0.label) }
        let pool = arrived.isEmpty ? bandNow : arrived
        var votes: [String: Int] = [:]
        for e in pool { if let s = e.section, !s.isEmpty { votes[s, default: 0] += 1 } }
        // A STRICT majority of the pool, so a band straddling two panes that both changed stays silent:
        // a wrong name would advertise sideways scrolling on a pane that has none.
        //
        // …and at least TWO labels, because ONE changed label is not a slide. A band is a row of an AX
        // container, and rows contain live readouts: Deliver's own page carries "13%",
        // "Completed in 00:01:21" and a running timecode, each of which re-labels itself every few
        // hundred ms with nothing scrolling anywhere. A single arrival is exactly what that looks like,
        // and it would advertise a sideways axis on a pane that never moved. A real burst — 4 wheel
        // ticks — brings a strip's next items in together (measured live on the Deliver carousel: five).
        // The cost of the rule is a slide that reveals exactly one item learning nothing THIS step,
        // which is the honest silence, not a denial.
        guard let winner = votes.max(by: { $0.value < $1.value }),
              winner.value >= 2, winner.value * 2 > pool.count else { return nil }
        return winner.key
    }

    private static func arrow(_ e: ScrollEvidence) -> String {
        switch (e.moreBelow, e.moreAbove) {
        case (true, true): return " ↕"
        case (true, false): return " ↓ (more below)"
        case (false, true): return " ↑ (more above)"
        case (false, false): return ""
        }
    }
}

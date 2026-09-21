import CoreGraphics

/// Groups raw detections (OCR text boxes + icon boxes) into COMPOSITE elements before the scene is built:
/// (1) merges fragmented OCR runs on one baseline into a single phrase, (2) pairs an icon with its
/// adjacent text (right-hand label, left-hand label, or caption below) into ONE "control" — so an export
/// icon next to the word "Export" reads as a single control instead of two unrelated boxes, and (3) pairs
/// a toggle SWITCH with its same-row label even across a wide settings-row gap ("Facebook … [switch]"),
/// carrying the pixel-read on/off state. An unlabeled icon INHERITS the paired text as its name — free
/// semantic coverage without manual labeling.
/// Pure geometry over pixel-space rects; fully offline-testable; thresholds scale with element size (DPI-free).
public enum ElementGrouper {

    public struct TextRun: Sendable, Equatable {
        public var rect: CGRect
        public var text: String
        public init(rect: CGRect, text: String) { self.rect = rect; self.text = text }
    }

    public struct Icon: Sendable, Equatable {
        public var rect: CGRect
        public var label: String?              // icon-DB label when the hash matched, else nil
        public var isToggle: Bool              // switch-shaped (caller decides, e.g. ToggleStateReader)
        public var isMark: Bool                // checkbox/radio-shaped — its label sits to the RIGHT
        public var state: String?              // "on" | "off" when the caller could read it from pixels
        public init(rect: CGRect, label: String? = nil, isToggle: Bool = false, isMark: Bool = false,
                    state: String? = nil) {
            self.rect = rect; self.label = label; self.isToggle = isToggle; self.isMark = isMark; self.state = state
        }
    }

    /// kind: "text" (pure text), "icon" (bare icon), "control" (icon+text composite).
    public struct Grouped: Sendable, Equatable {
        public var rect: CGRect
        public var kind: String
        public var label: String               // empty only when unlabeled
        public var unlabeled: Bool
        public var state: String?              // toggle state, when read
        public init(rect: CGRect, kind: String, label: String, unlabeled: Bool = false, state: String? = nil) {
            self.rect = rect; self.kind = kind; self.label = label; self.unlabeled = unlabeled; self.state = state
        }
    }

    /// Full pass: merge text fragments, then pair icons with their captions. Deterministic output order:
    /// composites, then remaining texts, then remaining icons (each in input order).
    public static func group(texts: [TextRun], icons: [Icon]) -> [Grouped] {
        let merged = mergeLines(texts)

        // Every icon claims its best caption; one text names at most one icon (closest gap wins, greedily).
        struct Claim { let icon: Int; let text: Int; let gap: CGFloat }
        var claims: [Claim] = []
        for (ii, ic) in icons.enumerated() {
            var best: (ti: Int, gap: CGFloat)?
            for (ti, t) in merged.enumerated() {
                guard t.text.count <= 48,                       // a caption, not a paragraph
                      isNameworthy(t.text),                     // "•••"/"›" misreads never name a control
                      t.rect.height <= 2.5 * ic.rect.height,    // caption-sized relative to the icon
                      let gap = pairGap(icon: ic.rect, text: t.rect) else { continue }
                // A SWITCH is never named by a caption to its RIGHT (or below): the settings convention
                // is label-LEFT, and that is the ROW pass's job. Without this a list's file-type icon
                // (a colored badge shape-passed as a switch) grabs the filename beside it and the row
                // reads as a bogus '[on] control' — measured on Finder ('premiere_agent_assets.zip [on]').
                if ic.isToggle, t.rect.minX >= ic.rect.minX - 0.2 * ic.rect.height { continue }
                if isNextListLine(icon: ic.rect, caption: t.rect, texts: merged) { continue }
                if best == nil || gap < best!.gap { best = (ti, gap) }
            }
            if let b = best { claims.append(Claim(icon: ii, text: b.ti, gap: b.gap)) }
        }

        var out: [Grouped] = []
        var consumedText = Set<Int>(), pairedIcon = Set<Int>()
        for c in claims.sorted(by: { ($0.gap, $0.icon) < ($1.gap, $1.icon) })
        where !consumedText.contains(c.text) && !pairedIcon.contains(c.icon) {
            let ic = icons[c.icon], t = merged[c.text]
            out.append(Grouped(rect: ic.rect.union(t.rect), kind: "control", label: t.text, state: ic.state))
            consumedText.insert(c.text); pairedIcon.insert(c.icon)
        }

        // MARK pass — a CHECKBOX or RADIO is named by the text on its RIGHT ("[x] Use vertical resolution"),
        // the opposite convention to a settings switch. The gap can exceed the generic caption cap because
        // the segmenter boxes the MARK (a selected radio's dot, measured 20px inside a 28px control), not
        // the control's outline, so its right edge sits a few px short of where the eye puts it.
        var markClaims: [Claim] = []
        for (ii, ic) in icons.enumerated() where !pairedIcon.contains(ii) && ic.isMark {
            var best: (ti: Int, gap: CGFloat)?
            for (ti, t) in merged.enumerated() {
                guard t.text.count <= 48, isNameworthy(t.text),
                      min(ic.rect.maxY, t.rect.maxY) - max(ic.rect.minY, t.rect.minY) >= 0.6 * min(ic.rect.height, t.rect.height)
                else { continue }
                let gap = t.rect.minX - ic.rect.maxX                          // label RIGHT of the box
                guard gap > -2, gap <= 2.5 * ic.rect.height else { continue }
                if best == nil || gap < best!.gap { best = (ti, gap) }
            }
            if let b = best { markClaims.append(Claim(icon: ii, text: b.ti, gap: b.gap)) }
        }
        for c in markClaims.sorted(by: { ($0.gap, $0.icon) < ($1.gap, $1.icon) })
        where !consumedText.contains(c.text) && !pairedIcon.contains(c.icon) {
            let ic = icons[c.icon]
            out.append(Grouped(rect: ic.rect, kind: "control", label: merged[c.text].text, state: ic.state))
            consumedText.insert(c.text); pairedIcon.insert(c.icon)
        }

        // ROW pass — settings-style rows where a TOGGLE sits far from its label on the same line
        // ("Facebook ………… [switch]"). Only switches row-pair (a toolbar of ordinary icons must NOT all
        // grab the row's leftmost text); the label must sit LEFT of the switch (settings convention —
        // guards against grabbing unrelated text from the panel to its right); nearest wins; a text
        // already consumed by a logo/chevron composite is BORROWABLE (the row's name belongs to the row's
        // toggle too). The grouped rect stays the SWITCH — the actionable hotspot, not the row's middle.
        var rowClaims: [Claim] = []
        for (ii, ic) in icons.enumerated() where !pairedIcon.contains(ii) && ic.isToggle {
            var best: (ti: Int, gap: CGFloat)?
            for (ti, t) in merged.enumerated() {
                guard t.text.count <= 48, isNameworthy(t.text),
                      min(ic.rect.maxY, t.rect.maxY) - max(ic.rect.minY, t.rect.minY) >= 0.6 * min(ic.rect.height, t.rect.height)
                else { continue }
                let gap = ic.rect.minX - t.rect.maxX                          // label LEFT of the switch
                guard gap > 0, gap <= 45 * ic.rect.height else { continue }   // settings rows run panel-wide
                if best == nil || gap < best!.gap { best = (ti, gap) }
            }
            if let b = best { rowClaims.append(Claim(icon: ii, text: b.ti, gap: b.gap)) }
        }
        // ONE switch per row label (unique-accept): when several switch candidates claim the SAME text,
        // the RIGHTMOST wins — settings rows end in their toggle; the extra claimant is almost always a
        // shape-passed impostor hugging the label (measured on Premiere's X row: Vision read the X LOGO
        // as the letter "X", the unread label text segmented as a 1.9-aspect box, and both it and the
        // real toggle borrowed the same label → a phantom "X [off]"). Losers DEMOTE to stateless
        // unlabeled icons, which the map tier filters out. Single-claim rows (compact prefs panes with
        // the toggle right beside its label) are untouched — demotion needs competition.
        var demoted = Set<Int>()
        let byText = Dictionary(grouping: rowClaims, by: \.text)
        for (_, claims) in byText where claims.count > 1 {
            let winner = claims.max { icons[$0.icon].rect.minX < icons[$1.icon].rect.minX }!
            for c in claims where c.icon != winner.icon { demoted.insert(c.icon) }
        }
        for c in rowClaims.sorted(by: { ($0.gap, $0.icon) < ($1.gap, $1.icon) })
        where !pairedIcon.contains(c.icon) && !demoted.contains(c.icon) {
            let ic = icons[c.icon]
            out.append(Grouped(rect: ic.rect, kind: "control", label: merged[c.text].text, state: ic.state))
            consumedText.insert(c.text); pairedIcon.insert(c.icon)
        }

        for (ti, t) in merged.enumerated() where !consumedText.contains(ti) {
            out.append(Grouped(rect: t.rect, kind: "text", label: t.text))
        }
        for (ii, ic) in icons.enumerated() where !pairedIcon.contains(ii) {
            let labeled = ic.label?.isEmpty == false
            // A demoted row-claim loser also loses its STATE — it isn't a switch, and a stateless
            // unlabeled icon never reaches the map.
            out.append(Grouped(rect: ic.rect, kind: "icon", label: labeled ? ic.label! : "",
                               unlabeled: !labeled, state: demoted.contains(ii) ? nil : ic.state))
        }
        return out
    }

    /// Merge OCR fragments that sit on one baseline with word-sized gaps into a single phrase (Vision often
    /// splits one label into runs). Never merges across columns (gap > ~0.9 line-heights) or font sizes
    /// (height ratio > 1.8 — a title never merges into body text).
    public static func mergeLines(_ texts: [TextRun]) -> [TextRun] {
        let runs = texts.sorted { $0.rect.midY != $1.rect.midY ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX }
        var used = [Bool](repeating: false, count: runs.count)
        var out: [TextRun] = []
        for i in runs.indices where !used[i] {
            var acc = runs[i]; used[i] = true
            var changed = true
            while changed {
                changed = false
                for j in runs.indices where !used[j] {
                    let a = acc.rect, b = runs[j].rect
                    let hMin = min(a.height, b.height), hMax = max(a.height, b.height)
                    guard hMin > 0, hMax / hMin <= 1.8, abs(a.midY - b.midY) <= 0.5 * hMin else { continue }
                    let gapRight = b.minX - a.maxX          // b continues acc to the right
                    let gapLeft = a.minX - b.maxX           // b precedes acc on the left
                    if gapRight >= -2, gapRight <= 0.9 * hMin {
                        acc = TextRun(rect: a.union(b), text: acc.text + " " + runs[j].text)
                    } else if gapLeft >= -2, gapLeft <= 0.9 * hMin {
                        acc = TextRun(rect: a.union(b), text: runs[j].text + " " + acc.text)
                    } else { continue }
                    used[j] = true; changed = true
                }
            }
            out.append(acc)
        }
        return out
    }

    /// A detected switch. `inferredState` is set when GEOMETRY already tells the state (knob-side) —
    /// more reliable than any pixel read; nil means the caller should read pixels. `assumed` marks the
    /// unanchored-column fallback: the caller MUST pixel-validate the knob (plain disc, not a logo).
    public struct Switch: Sendable, Equatable {
        public let rect: CGRect
        public let inferredState: String?
        public let assumed: Bool
        public init(rect: CGRect, inferredState: String?, assumed: Bool = false) {
            self.rect = rect; self.inferredState = inferredState; self.assumed = assumed
        }
        /// The knob-square region of an assumed switch (its origin square) — what to pixel-validate.
        public var knobSquare: CGRect { CGRect(x: rect.minX, y: rect.minY, width: rect.height, height: rect.height) }
        public var rightEndSquare: CGRect { CGRect(x: rect.maxX - rect.height, y: rect.minY, width: rect.height, height: rect.height) }
    }

    /// Coalesce segments sitting within `gap` px of one another (union-find) into their bounding unions —
    /// a low-contrast control splits into pieces (a switch's knob + track end, a checkbox's frame + tick)
    /// whose UNION is the real control. Sorted top-to-bottom so every caller sees the same order.
    static func coalesce(segments: [CGRect], gap: CGFloat) -> [CGRect] {
        var parent = Array(segments.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in segments.indices {
            for j in (i + 1)..<segments.count where segments[i].insetBy(dx: -gap, dy: -gap).intersects(segments[j]) {
                parent[find(j)] = find(i)
            }
        }
        var unions: [Int: CGRect] = [:]
        for i in segments.indices {
            let r = find(i)
            unions[r] = unions[r].map { $0.union(segments[i]) } ?? segments[i]
        }
        return unions.values.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// CHECKBOX / RADIO candidates — the SQUARE-ish unions, where a switch is the pill-shaped ones. Unlike
    /// a switch, such a control carries its state INSIDE (a tick, a selected radio's dot), so it needs no
    /// column and no anchoring pill to be readable.
    ///
    /// Geometry cannot tell a hollow checkbox from an app logo of the same size, so these are only
    /// candidates: the caller confirms each one with pixels (`ToggleStateReader.markState`), which is also
    /// what supplies the state.
    public static func markCandidates(segments: [CGRect], gap: CGFloat = 5,
                                      isMarkShaped: (CGRect) -> Bool) -> [CGRect] {
        coalesce(segments: segments, gap: gap).filter(isMarkShaped)
    }

    /// Detect switches among raw segments. Two mechanisms:
    /// (1) coalesce fragments within `gap` px (union-find) — a low-contrast toggle can split into
    ///     knob+track pieces whose UNION is switch-shaped;
    /// (2) KNOB-ONLY recovery — an OFF switch on a dark panel often renders just its knob (a square;
    ///     the track has no edge contrast). A square vertically stacked INSIDE the x-range of a known
    ///     full pill in the same column is that column's switch, and the knob's side inside the pill
    ///     IS the state: left = off, right = on. Deterministic top-to-bottom order.
    public static func toggleCandidates(segments: [CGRect], gap: CGFloat = 5,
                                        isToggleShaped: (CGRect) -> Bool) -> [Switch] {
        let unions = coalesce(segments: segments, gap: gap)
        let pills = unions.filter(isToggleShaped)
        var switches = pills.map { Switch(rect: $0, inferredState: nil) }
        let squares = unions.filter { u in
            let aspect = u.width / max(u.height, 1)
            return !pills.contains(u) && aspect >= 0.8 && aspect <= 1.25 && u.height >= 12 && u.height <= 100
        }
        var unanchored: [CGRect] = []
        for u in squares {
            if let p = pills.first(where: {
                abs($0.height - u.height) <= 0.25 * $0.height                     // same-size control
                    && u.minX >= $0.minX - 4 && u.maxX <= $0.maxX + 4 }) {        // inside the pill column
                let pill = CGRect(x: p.minX, y: u.midY - p.height / 2, width: p.width, height: p.height)
                switches.append(Switch(rect: pill, inferredState: u.midX < pill.midX ? "off" : "on"))
            } else {
                unanchored.append(u)
            }
        }
        // UNANCHORED column fallback: when EVERY switch in a column is off, no pill exists anywhere to
        // anchor it (e.g. all export destinations disabled). But ≥2 same-size squares sharing a left edge
        // is a settings column; assume the standard pill ratio with the knob at the LEFT edge (the off
        // convention) and let the caller's pixel read confirm the state. A LONE square stays an icon.
        for u in unanchored {
            let siblings = unanchored.filter {
                abs($0.minX - u.minX) <= 4 && abs($0.height - u.height) <= 0.25 * u.height
            }
            guard siblings.count >= 2 else { continue }
            switches.append(Switch(rect: CGRect(x: u.minX, y: u.minY, width: 1.7 * u.height, height: u.height),
                                   inferredState: nil, assumed: true))
        }
        return switches.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    /// Is this segment a TEXT GLYPH rather than an icon — a bullet, bracket or punctuation mark OCR
    /// skipped, sitting on a text baseline? Two shapes qualify: SMALL (longest side ≤ 0.6 of the frame's
    /// OCR line height — a "•" or "▸" is ~0.4–0.6 of its line; a real toolbar/expander icon is ≥ 0.75) or
    /// THIN (width ≤ half its height, no taller than ~1.4 lines — "(" "|" ":"). Either must also share a
    /// baseline with an OCR run within one line height. Measured on a terminal frame: every "•", "▸",
    /// "(" became an unlabeled icon and then ANCHORED a false control with the line beside it.
    /// A THUMBNAIL: a box with a caption text line directly beneath it, horizontally centred on it
    /// (Keynote's theme chooser, Finder icon view, media-pool tiles). Such a box is a gallery item
    /// even when it is far larger than an icon — measured on Keynote themes, the 0.14·min-side icon
    /// cap dropped 5 theme tiles (335×190 in a 2142×1480 crop) that the human annotated as icons.
    /// The caption must be no wider than the box (a paragraph under a photo is not a caption).
    public static func hasCaptionBelow(_ box: CGRect, ocrBoxes: [CGRect]) -> Bool {
        guard box.width > 0, box.height > 0 else { return false }
        return ocrBoxes.contains { t in
            let vGap = t.minY - box.maxY
            return vGap >= -2 && vGap <= 0.25 * box.height
                && t.width <= 1.05 * box.width && t.height <= 0.3 * box.height
                && abs(t.midX - box.midX) <= 0.2 * box.width
        }
    }

    /// Two consecutive LIST LINES are not icon + caption: when the 'icon' is itself a labelled box (a text
    /// run covers ≥60% of it) and the candidate caption BELOW has that text's font height and shares its
    /// LEFT edge, the caption is the next row of a list/menu. A real caption is centred under a thumbnail
    /// and a button's inner label is not left-aligned with the line beneath. Measured on Resolve's Clip
    /// Color menu: the 'Orange' word blob took 'Apricot' beneath it → a control at the wrong row.
    static func isNextListLine(icon i: CGRect, caption t: CGRect, texts: [TextRun]) -> Bool {
        guard t.minY - i.maxY >= -2 else { return false }                       // only the BELOW case
        return texts.contains { u in
            let x = i.intersection(u.rect)
            guard !x.isNull, x.width * x.height >= 0.6 * i.width * i.height else { return false }
            return u.rect.height >= 0.8 * t.height && u.rect.height <= 1.25 * t.height
                && abs(u.rect.minX - t.minX) <= 0.5 * t.height
        }
    }

    public static func isTextGlyph(_ seg: CGRect, ocrBoxes: [CGRect], lineHeight: CGFloat) -> Bool {
        guard lineHeight > 0, seg.width > 0, seg.height > 0 else { return false }
        let small = max(seg.width, seg.height) <= 0.6 * lineHeight
        let thin = seg.width <= 0.5 * seg.height && seg.height <= 1.4 * lineHeight
        guard small || thin else { return false }
        return ocrBoxes.contains { o in
            let vOverlap = min(seg.maxY, o.maxY) - max(seg.minY, o.minY)
            guard vOverlap >= 0.5 * seg.height else { return false }
            let hGap = max(o.minX - seg.maxX, seg.minX - o.maxX)     // negative when they overlap
            return hGap <= lineHeight
        }
    }

    /// Can this text NAME a control? Punctuation-only OCR reads ("•••", "›", "...") are chrome misreads,
    /// not captions — a name needs at least one letter or digit.
    static func isNameworthy(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Does REAL text overlap this switch candidate? Vision misreads switch chrome as short glyph runs
    /// ("O", "C", "CC", "…") — those must never veto a switch. Only an actual word (≥3 chars, nameworthy)
    /// covering ≥25% of the box means "this is text, not a switch".
    public static func switchVetoedByText(_ rect: CGRect, runs: [(text: String, box: CGRect)]) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return runs.contains { r in
            let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3, isNameworthy(t) else { return false }
            let inter = r.box.intersection(rect)
            return !inter.isNull && inter.width * inter.height >= 0.25 * rect.width * rect.height
        }
    }

    /// A lone circle-like OCR read ("O", "0", "•"…) is almost always a shape misread — Vision sees a
    /// switch KNOB or a radio dot and calls it a letter. These must not count as text (they'd veto the
    /// switch as "overlapping text") nor appear as scene elements. Multi-char runs are never dropped.
    public static func isKnobGlyph(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 1, let c = t.first else { return false }
        return "O0o•◦●○◎◉⚪⬤".contains(c)
    }

    /// Is this text the icon's caption? Returns the separation gap (smaller = stronger pair) or nil.
    /// Three layouts: label right of icon ("[icon] Export"), label left of icon ("H.264 [caret]" — dropdowns),
    /// caption below ("[icon]" over "Effects" — toolbars/docks). All thresholds scale with the icon.
    static func pairGap(icon i: CGRect, text t: CGRect) -> CGFloat? {
        let vOverlap = min(i.maxY, t.maxY) - max(i.minY, t.minY)
        let aligned = vOverlap >= 0.5 * min(i.height, t.height)
        let side = 0.9 * i.height                            // max horizontal gap for a side label
        if aligned {
            let gapRight = t.minX - i.maxX
            if gapRight >= -2, gapRight <= side { return max(0, gapRight) }
            let gapLeft = i.minX - t.maxX
            if gapLeft >= -2, gapLeft <= side { return max(0, gapLeft) }
        }
        let vGap = t.minY - i.maxY                           // caption strictly below
        // CENTERED under the icon, judged against the ICON. The old max(icon, text) tolerance let a wide
        // label pass trivially — a list's NEXT ROW ("premiere_agent_assets", 326px, left-aligned under
        // a 32px folder icon) read as that icon's caption and every Finder row became a 2-row control.
        // A real caption is centered (toolbar labels, grid captions); a next-row label is left-aligned.
        if vGap >= -2, vGap <= 0.7 * i.height, abs(t.midX - i.midX) <= max(0.6 * i.width, 0.3 * t.width) {
            return max(0, vGap) + 0.5                        // slight penalty: side labels beat captions at a tie
        }
        return nil
    }
}

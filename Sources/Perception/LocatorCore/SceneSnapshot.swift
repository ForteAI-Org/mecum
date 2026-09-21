import Foundation
import CoreGraphics

/// One element in a text SCENE — the image-free view an LLM consumes instead of a screenshot. Carries only
/// a stable id, a human-meaningful `label`, a kind, a normalized position, and (for controls) state. It has
/// NO crop / edge-hash / AX-path / pixel field by construction — the image-free boundary is a type property,
/// not a runtime promise.
public struct SceneElement: Codable, Equatable, Sendable {
    public var id: String                 // stable identityKey (digit-sensitive; never a coordinate)
    public var kind: String               // "text" | "icon" | "control"
    public var label: String              // OCR text, icon-DB label, or "(unlabeled)" — what the LLM names
    public var pos: [Double]              // [x, y, w, h], window-normalized 0..1 (disambiguation only)
    public var role: String?              // AX role when known
    public var state: String?             // "on" | "off" | "unknown" for a stateful control
    /// Accessibility value, kept distinct from the label that identifies a control.
    public var value: String?
    public var unlabeled: Bool?           // true for an icon with no label yet (an honest coverage gap)
    public var group: String?             // brain sibling-group tag, e.g. "Destinations#3" (ordinal identity)
    public var recalled: Bool?            // true when the LABEL came from the brain (position is always live)
    public var does: String?              // trusted learned affordances, e.g. "click: toggles" (evidence ≥ 2)
    public var section: String?           // named window PANEL this element lives in ("TRACKS", "CLIPS")

    public init(id: String, kind: String, label: String, pos: [Double],
                role: String? = nil, state: String? = nil, value: String? = nil, unlabeled: Bool? = nil,
                group: String? = nil, recalled: Bool? = nil, does: String? = nil, section: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.pos = pos
        self.role = role; self.state = state; self.value = value; self.unlabeled = unlabeled
        self.group = group; self.recalled = recalled; self.does = does; self.section = section
    }
}

/// A text snapshot of one app window for an LLM: app context + the fused element list (OCR text + labeled
/// icons + controls) + the available menu commands. Image-free; serializes to compact JSON or a legible table.
public struct SceneSnapshot: Codable, Equatable, Sendable {
    public var bundleID: String
    public var app: String
    public var windowTitle: String
    public var viewportPx: [Int]          // [w, h]
    public var elements: [SceneElement]
    public var sections: [SceneSection]   // named window panels (empty when detection found none)
    public var commands: [String]         // menu paths (e.g. "File > Export…"), summary
    /// Content+state hash the LLM echoes back when acting; the actuator refuses if the LIVE token has drifted
    /// (the screen changed since the LLM looked) — the TOCTOU guard for actions.
    public var token: String

    public init(bundleID: String, app: String, windowTitle: String, viewportPx: [Int],
                elements: [SceneElement], sections: [SceneSection] = [], commands: [String], token: String = "") {
        self.bundleID = bundleID; self.app = app; self.windowTitle = windowTitle
        self.viewportPx = viewportPx; self.elements = elements; self.sections = sections; self.commands = commands
        self.token = token.isEmpty ? SceneSnapshot.makeToken(bundleID: bundleID, windowTitle: windowTitle, elements: elements) : token
    }

    /// Deterministic, process-STABLE token over the window's content + control states (FNV-1a; NOT Swift's
    /// randomized hashValue). Same screen → same token; any element/state change → different token.
    public static func makeToken(bundleID: String, windowTitle: String, elements: [SceneElement]) -> String {
        let body = elements.map { "\($0.id)|\($0.state ?? "")" }.sorted().joined(separator: ";")
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(bundleID)\n\(windowTitle)\n\(body)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// How a target string resolved against this scene.
    public enum Resolution: Equatable {
        case found(SceneElement)
        case ambiguous(Int)      // n same-label matches — caller must ask for an id
        case none
    }

    /// Resolve an action target: element id (exact) preferred, else a unique case-insensitive label.
    /// With `preferStateful` (set_toggle), a label shared by several elements narrows to the ones carrying
    /// state — a row's grouped SWITCH wins over its logo/text composite, which shares the row's name by design.
    public func resolve(target: String, preferStateful: Bool = false, section: String? = nil) -> Resolution {
        // Optional SECTION filter disambiguates same-label (and same-id) elements — e.g. two "Export"
        // both keyed "?|export", one in "region 1" (tab), one in "region 10" (footer button). The
        // identity key is role|text and collides by design (position-independent for the brain), so the
        // section is how the caller picks which one.
        func inSection(_ e: SceneElement) -> Bool {
            guard let section, !section.isEmpty else { return true }
            return e.section?.caseInsensitiveCompare(section) == .orderedSame
        }
        if let byId = elements.first(where: { $0.id == target && inSection($0) }) { return .found(byId) }
        // Tolerate the model echoing the MAP's DISPLAY string: the map renders state as a trailing
        // " [on]/[off]" and group ordinals as " (row#6)" (SceneSnapshot.mapText / enrich), so a model
        // that reads "Vimeo [off]" and passes it verbatim must still resolve to the "Vimeo" element.
        // Exact match first; the annotation-stripped label is a fallback (never masks a real "Foo (Bar)").
        let cleaned = Self.stripDisplayAnnotations(target)
        var byLabel = elements.filter { inSection($0) && $0.label.caseInsensitiveCompare(target) == .orderedSame }
        if byLabel.isEmpty, cleaned != target {
            byLabel = elements.filter { inSection($0) && Self.stripDisplayAnnotations($0.label).caseInsensitiveCompare(cleaned) == .orderedSame }
        }
        // Tier 3: CORE-label match. OCR fuses the avatar glyph into a DIFFERENT junk prefix every frame
        // ('Ze Simone' / 'Za Simone' / '¿ Simone' — measured: a saved route died because its stored
        // label never re-appeared verbatim), and channel names carry punctuation ('#_all-team' vs the
        // user's "all team"). Compare junk-stripped, punctuation-free cores; unique-accept as always.
        if byLabel.isEmpty {
            let want = Self.coreKey(cleaned)
            if !want.isEmpty {
                byLabel = elements.filter { inSection($0) && Self.coreKey($0.label) == want }
            }
        }
        if preferStateful, byLabel.count > 1 {
            let stateful = byLabel.filter { $0.state != nil }
            if !stateful.isEmpty { byLabel = stateful }
        }
        if byLabel.count == 1 { return .found(byLabel[0]) }
        return byLabel.isEmpty ? .none : .ambiguous(byLabel.count)
    }

    /// Junk-tolerant identity of a label: lowercase alphanumeric tokens, leading tokens of ≤2 chars
    /// dropped (avatar-glyph OCR junk), joined without punctuation. "Ze Simone" → "simone",
    /// "#_all-team" → "allteam". Deliberately conservative: only LEADING short tokens are junk.
    static func coreKey(_ s: String) -> String {
        var toks = KnowledgeText.tokens(s)
        while toks.count > 1, toks[0].count <= 2 { toks.removeFirst() }
        return toks.joined()
    }

    /// The elements a target matches (same rule as `resolve`) — for a disambiguation message that LISTS
    /// the candidates with their ids + sections, so the model can pick the right one (e.g. the Export
    /// BUTTON in the footer vs the Export TAB up top, both labeled "Export").
    public func candidates(target: String) -> [SceneElement] {
        let exact = elements.filter { $0.label.caseInsensitiveCompare(target) == .orderedSame }
        if !exact.isEmpty { return exact }
        let cleaned = Self.stripDisplayAnnotations(target)
        return elements.filter { Self.stripDisplayAnnotations($0.label).caseInsensitiveCompare(cleaned) == .orderedSame }
    }

    /// A one-line disambiguation hint: retry the SAME target with a `section` arg. Lists each candidate's
    /// section + position so the caller can pick (e.g. the footer "Export" button vs the top tab).
    public func disambiguation(target: String, limit: Int = 6) -> String {
        candidates(target: target).prefix(limit).map { e in
            let pos = e.pos.count == 4 ? String(format: "@%.2f,%.2f", e.pos[0], e.pos[1]) : ""
            return "section:'\(e.section ?? "?")' \(pos)"
        }.joined(separator: " OR ")
    }

    /// Strip trailing display annotations the map appends — " [state]" and " (ordinal)" — so a target
    /// copied from the rendered map still matches the bare element label. Peels repeatedly (a control can
    /// carry both, e.g. "Media File (row#3) [off]").
    static func stripDisplayAnnotations(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("]") || t.hasSuffix(")") {
            let opener = t.hasSuffix("]") ? " [" : " ("
            guard let r = t.range(of: opener, options: .backwards) else { break }
            t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// Fuzzy GREP of the scene for a GOAL phrase — the server-side "find it for the model" primitive.
    /// A small LLM handed a 93-element map cannot reliably spot that "Simone chat" means the sidebar
    /// item "Ze Simone" (OCR junk prefix included) — but a token grep can, in microseconds. Content
    /// tokens only (go/to/chat-style filler stripped by the caller's query is fine too — filler simply
    /// won't match); whole-token hits count 1, substring hits (≥4 chars, catches OCR-fused labels)
    /// count 0.7; controls outrank prose. Returns best-first (element, score); callers CLICK only a
    /// UNIQUE top scorer and otherwise list candidates.
    public func grep(goal: String, limit: Int = 5) -> [(element: SceneElement, score: Double)] {
        let phrase = Route.contentPhrase(goal)
        let q = KnowledgeText.tokens(phrase.isEmpty ? goal : phrase).map { KnowledgeText.normalize($0) }.filter { !$0.isEmpty }
        guard !q.isEmpty else { return [] }
        var scored: [(SceneElement, Double)] = []
        for e in elements where e.unlabeled != true {
            let ltoks = KnowledgeText.tokens(e.label).map { KnowledgeText.normalize($0) }
            guard !ltoks.isEmpty else { continue }
            var hits = 0.0
            for t in q {
                if ltoks.contains(t) { hits += 1 }
                else if t.count >= 4, ltoks.contains(where: { $0.contains(t) }) { hits += 0.7 }
            }
            guard hits > 0 else { continue }
            var score = hits / Double(q.count)
            if e.kind == "control" { score += 0.1 }   // actionable beats message prose
            scored.append((e, score))
        }
        return Array(scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.label.count < $1.0.label.count }.prefix(limit))
    }

    /// The smallest SECTION containing a window-normalized point — where a click landed when no element
    /// was under it ("somewhere in CLIPS" beats "?" in the behavior timeline).
    public func sectionAt(_ point: CGPoint) -> SceneSection? {
        sections.filter { s in
            guard s.pos.count == 4 else { return false }
            return CGRect(x: s.pos[0], y: s.pos[1], width: s.pos[2], height: s.pos[3]).contains(point)
        }.min { ($0.pos[2] * $0.pos[3]) < ($1.pos[2] * $1.pos[3]) }
    }

    /// The smallest element whose normalized bounds contain `point` (a window-normalized 0..1 point) — used
    /// to resolve WHAT a click landed on. nil if the point is over no described element.
    public func elementAt(_ point: CGPoint) -> SceneElement? {
        elements.filter { e in
            guard e.pos.count == 4 else { return false }
            let r = CGRect(x: e.pos[0], y: e.pos[1], width: e.pos[2], height: e.pos[3])
            return r.contains(point)
        }.min { ($0.pos[2] * $0.pos[3]) < ($1.pos[2] * $1.pos[3]) }
    }

    /// The MAP tier (B5): sections with counts + up to `notable` elements each — stateful controls
    /// first (actionable state must never be hidden by summarization), then learned affordances, then
    /// labeled controls. ~2k chars where the full scene is ~90k: cheap enough for the LLM to look
    /// constantly, with `describe_section` as the drill-down. Same token (acting stays guarded).
    public func mapText(notable: Int = 8) -> String {
        guard !sections.isEmpty else { return text() }   // no structure detected → the flat list IS the map
        var out = "app: \(app) (\(bundleID))\(windowTitle.isEmpty ? "" : " — \"\(windowTitle)\"")\n"
        out += "map: \(elements.count) elements in \(sections.count) sections (describe_section(name) drills in)\n"
        for s in sections {
            let members = elements.filter { $0.section == s.name }
            let p = s.pos.count == 4 ? String(format: "%.2f,%.2f %.2f×%.2f", s.pos[0], s.pos[1], s.pos[2], s.pos[3]) : "?"
            // Scrollability is MAP-tier information: "more below" changes what the model does next
            // (reach instead of concluding the target doesn't exist).
            out += "▣ \(s.name)  @ \(p) — \(members.count) elements\(s.scrolls.map { " · \($0)" } ?? "")\(s.scrollsX.map { " · \($0)" } ?? "")\n"
            func rank(_ e: SceneElement) -> Int {
                if e.state != nil { return 0 }                          // actionable state: never hidden
                if e.does != nil { return 1 }                           // learned affordance
                // Labeled ICONS rank with controls: a user hand-named that icon (icon-DB label) — the
                // most deliberate signal in the scene. Ranked last, "call" fell into "+5 more" and the
                // model messaged Simone instead of calling him (measured).
                if (e.kind == "control" || e.kind == "icon") && e.unlabeled != true { return 2 }
                return 3
            }
            // TIES BREAK ON SCENE ORDER, never arbitrarily: an open menu's rows all share x = 0 (they are
            // full-width), so rank+x left them unordered and Swift's sort is not stable — the same menu
            // could print its fonts in a different order twice in a row. Scene order IS menu order.
            let ranked = members.enumerated().sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                if ra != rb { return ra < rb }
                let xa = a.element.pos.first ?? 0, xb = b.element.pos.first ?? 0
                return xa != xb ? xa < xb : a.offset < b.offset
            }.map(\.element)
            // SMALL sections show EVERYTHING: the X-Y cut mosaics content grids into "region N" tiles
            // of a handful of elements each, and truncating those forced the model into a
            // describe_section call per tile just to list what a couple more map lines would have said
            // (measured: five drill-downs to enumerate Creative Cloud's apps grid). Dense sections keep
            // the `notable` cap — the map must stay a map.
            // Keep labeled elements, AND unlabeled ones that carry STATE — an actionable toggle must
            // never be hidden just because its icon has no caption (measured: Premiere's "X" export
            // row is a logo with no text → was invisible though it has an on/off toggle).
            // FILTER BEFORE TRUNCATING: the other order let nameless clutter spend the budget and then
            // vanish, so a 9-element section printed 4 lines and claimed "+5 more" — the model then
            // paid a describe_section round-trip to discover the rest was nothing (measured live).
            let showable = ranked.filter { $0.unlabeled != true || $0.state != nil }
            // AN OPEN MENU IS THE INTERACTION SURFACE, so its rows ARE the map, not a footnote behind a
            // drill-down: the whole point of enumerating a long menu is that the agent can pick
            // "Zapfino" from a font list in one call (measured: the old first-page-only scene made
            // act("Helvetica") an honest miss). Bounded so a 300-row menu still can't run away with it.
            let budget = showable.count <= 10 ? showable.count
                : (s.name == "open menu" ? min(60, showable.count) : notable)
            let shown = showable.prefix(budget)
            for e in shown {
                let st = e.state.map { " [\($0)]" } ?? ""
                let d = e.does.map { " — \($0)" } ?? ""
                // An unlabeled icon has no unique label to target — give the model its id to act on.
                let lbl = e.unlabeled == true ? "(unlabeled icon — target id '\(e.id)')" : e.label
                out += "    \(lbl)\(st)\(d)\n"
            }
            // Count only what a drill-down would actually ADD — nameless clutter isn't hidden content,
            // and advertising it as such is what invites the pointless round-trip.
            if showable.count > shown.count { out += "    … +\(showable.count - shown.count) more (describe_section)\n" }
        }
        let loose = elements.filter { $0.section == nil }.count
        if loose > 0 { out += "(+\(loose) unsectioned elements)\n" }
        if !commands.isEmpty { out += "commands: \(commands.count) menu paths known\n" }
        return out
    }

    /// Compact, LLM/human-legible rendering. With sections: a MAP — elements nested under their named
    /// panel, panels in reading order. Without: the flat one-line-per-element list.
    public func text() -> String {
        var out = "app: \(app) (\(bundleID))\(windowTitle.isEmpty ? "" : " — \"\(windowTitle)\"")\n"
        out += "viewport: \(viewportPx.first ?? 0)x\(viewportPx.count > 1 ? viewportPx[1] : 0)\n"
        func line(_ e: SceneElement, indent: String) -> String {
            let p = e.pos.count == 4 ? String(format: "%.2f,%.2f", e.pos[0], e.pos[1]) : "?"
            let st = e.state.map { " [\($0)]" } ?? ""
            let tag = (e.unlabeled == true) ? "icon?" : e.kind
            let g = e.group.map { " (\($0))" } ?? ""
            let rec = (e.recalled == true) ? " ~recalled" : ""
            let d = e.does.map { " — \($0)" } ?? ""
            return "\(indent)[\(tag)] \(e.label)\(st)\(g)\(rec)\(d)  @ \(p)\n"
        }
        if sections.isEmpty {
            out += "elements (\(elements.count)):\n"
            for e in elements { out += line(e, indent: "  ") }
        } else {
            out += "elements (\(elements.count)) in \(sections.count) sections:\n"
            for s in sections {
                let members = elements.filter { $0.section == s.name }
                let p = s.pos.count == 4 ? String(format: "%.2f,%.2f %.2f×%.2f", s.pos[0], s.pos[1], s.pos[2], s.pos[3]) : "?"
                out += "▣ \(s.name)  @ \(p) — \(members.count) elements\(s.scrolls.map { " · \($0)" } ?? "")\(s.scrollsX.map { " · \($0)" } ?? "")\n"
                for e in members { out += line(e, indent: "    ") }
            }
            let loose = elements.filter { $0.section == nil }
            if !loose.isEmpty {
                out += "▣ (unsectioned) — \(loose.count) elements\n"
                for e in loose { out += line(e, indent: "    ") }
            }
        }
        if !commands.isEmpty {
            out += "commands (\(commands.count)): " + commands.prefix(40).joined(separator: " · ") + "\n"
        }
        return out
    }
}

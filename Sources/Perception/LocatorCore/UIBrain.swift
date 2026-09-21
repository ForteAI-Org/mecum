import Foundation
import CoreGraphics

// The UI BRAIN — the persistent per-app world model layered over per-frame perception (see
// docs/UI_BRAIN_PLAN.md). B0: anchored objects + sibling groups, built passively from scenes.
// The brain DESCRIBES, never AIMS: boundsTypical is a hint for matching/annotation, never a click
// target — every action still re-perceives live.

/// An ANCHORED element: one persistent object across many observations (the "Facebook switch" seen
/// 47 times), robust to OCR jitter (aliases), state changes (statesSeen) and small moves.
public struct UIObjectAnchor: Codable, Equatable, Sendable {
    public var anchorKey: String            // opaque stable id (UUID string)
    public var kind: String                 // "control" | "icon"
    public var label: String                // canonical label ("" if never labeled)
    /// The NAMING LEDGER's provenance (B5): "observed" = from perception (captions, icon-DB via a
    /// scene) — updates freely; "llm" = deliberately assigned — IMMUTABLE to observation churn (a
    /// misread caption must never overwrite an approved name). nil (legacy) behaves as "observed".
    public var labelSource: String?
    public var aliases: [String]            // other labels seen for the same object ("X" vs "X X")
    public var boundsTypical: [Double]      // latest normalized [x,y,w,h] — a HINT, never a target
    public var statesSeen: [String: Int]    // "on": 12, "off": 40
    public var groupID: UUID?               // sibling-group membership
    public var seenCount: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// The brain's `ingestEpoch` when this object was last matched — forgetting is measured in
    /// OBSERVATIONS OF THE APP, never in days (see `BrainUpdater.decay`). nil = legacy row, stamped
    /// with the current epoch on the next ingest so it starts ageing from there, not from 2026.
    public var lastSeenEpoch: Int?
    /// The WINDOW (title letters-family) this object was last seen in. Forgetting is scoped to it: parses
    /// of the Edit page are not evidence that a Bounce-dialog control is gone. nil = legacy/unscoped —
    /// aged by the brain-wide clock instead.
    public var window: String?

    /// A name a person or the model ASSIGNED (`labelSource` "llm"/"user") is knowledge the app can never
    /// take back by merely not showing the control for a while: decay keeps it until a contradiction
    /// retracts it (ADR 0001). Observed names come and go with the pixels.
    public var isProtected: Bool { labelSource == "llm" || labelSource == "user" }   // "user" reserved for a direct-teach path

    public init(anchorKey: String = UUID().uuidString, kind: String, label: String, labelSource: String? = nil,
                aliases: [String] = [], boundsTypical: [Double], statesSeen: [String: Int] = [:],
                groupID: UUID? = nil, seenCount: Int = 1, firstSeen: Date, lastSeen: Date, lastSeenEpoch: Int? = nil,
                window: String? = nil) {
        self.anchorKey = anchorKey; self.kind = kind; self.label = label; self.labelSource = labelSource
        self.aliases = aliases
        self.boundsTypical = boundsTypical; self.statesSeen = statesSeen; self.groupID = groupID
        self.seenCount = seenCount; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.lastSeenEpoch = lastSeenEpoch
        self.window = window
    }
}

/// A learned CAUSAL edge (B2 fills these by diffing scenes across user input events). Only ever
/// trusted at `evidence >= 2` — one click coinciding with a redraw is not causality.
public struct UITransition: Codable, Equatable, Sendable {
    public var anchorKey: String
    public var trigger: String              // "hover" | "click" | "rightclick"
    public var effect: String               // compact: "stateFlip:off>on" | "menuOpened:A|B|C" | "elementsAppeared:…"
    public var evidence: Int
    public var lastObserved: Date
    public var lastObservedEpoch: Int?      // see UIObjectAnchor.lastSeenEpoch

    public init(anchorKey: String, trigger: String, effect: String, evidence: Int = 1, lastObserved: Date,
                lastObservedEpoch: Int? = nil) {
        self.anchorKey = anchorKey; self.trigger = trigger; self.effect = effect
        self.evidence = evidence; self.lastObserved = lastObserved; self.lastObservedEpoch = lastObservedEpoch
    }
}

/// A structural SIBLING group: aligned, same-size, same-kind elements (the Premiere Destinations
/// switch column). Membership implies nature — a square in a known switch column IS a switch —
/// and ordinal position is part of identity ("3rd switch in Destinations").
public struct SiblingGroup: Codable, Equatable, Sendable {
    public var id: UUID
    public var axis: String                 // "column" | "row"
    public var memberAnchors: [String]      // ordered by position along the axis
    public var sharedKind: String
    public var cellSize: [Double]           // normalized typical member [w,h]
    public var name: String?                // nearest header text ("Destinations")
    public var seenCount: Int
    public var lastSeen: Date
    public var lastSeenEpoch: Int?          // see UIObjectAnchor.lastSeenEpoch

    public init(id: UUID = UUID(), axis: String, memberAnchors: [String], sharedKind: String,
                cellSize: [Double], name: String? = nil, seenCount: Int = 1, lastSeen: Date, lastSeenEpoch: Int? = nil) {
        self.id = id; self.axis = axis; self.memberAnchors = memberAnchors; self.sharedKind = sharedKind
        self.cellSize = cellSize; self.name = name; self.seenCount = seenCount; self.lastSeen = lastSeen
        self.lastSeenEpoch = lastSeenEpoch
    }
}

/// The per-app brain payload (nested in AppKnowledge; all-absent decodes to empty for back-compat).
public struct UIBrain: Codable, Equatable, Sendable {
    public var objects: [UIObjectAnchor]
    public var groups: [SiblingGroup]
    public var transitions: [UITransition]
    /// How many times this brain has ingested a scene — the clock everything forgets by. An app that
    /// is not looked at does not forget: measured 2026-09-06, wall-clock decay wiped the three pro-app
    /// brains (Pro Tools/DaVinci/Premiere → 3/3/1 anchors, every taught name gone) because their
    /// `lastSeen` only moved on watcher ingests and the watcher was dormant for weeks, while apps
    /// nobody touched kept everything. Absent in legacy JSON → 0.
    public var ingestEpoch: Int
    /// When the clock last ticked. One OBSERVATION is a ten-minute block of activity on the app, not a
    /// frame: a scroll burst or an act's two scenes are one look (a per-parse clock made "150
    /// observations" mean two minutes of scrolling — found by review, 2026-09-06).
    public var lastEpochAdvance: Date?
    /// Per-WINDOW observation counters (title letters-family → count): parses of one window are evidence of
    /// absence only for anchors last seen in that window.
    public var windowEpochs: [String: Int]

    public init(objects: [UIObjectAnchor] = [], groups: [SiblingGroup] = [], transitions: [UITransition] = [],
                ingestEpoch: Int = 0, lastEpochAdvance: Date? = nil, windowEpochs: [String: Int] = [:]) {
        self.objects = objects; self.groups = groups; self.transitions = transitions; self.ingestEpoch = ingestEpoch
        self.lastEpochAdvance = lastEpochAdvance; self.windowEpochs = windowEpochs
    }

    private enum CodingKeys: String, CodingKey { case objects, groups, transitions, ingestEpoch, lastEpochAdvance, windowEpochs }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        objects = try c.decodeIfPresent([UIObjectAnchor].self, forKey: .objects) ?? []
        groups = try c.decodeIfPresent([SiblingGroup].self, forKey: .groups) ?? []
        transitions = try c.decodeIfPresent([UITransition].self, forKey: .transitions) ?? []
        ingestEpoch = try c.decodeIfPresent(Int.self, forKey: .ingestEpoch) ?? 0
        lastEpochAdvance = try c.decodeIfPresent(Date.self, forKey: .lastEpochAdvance)
        windowEpochs = try c.decodeIfPresent([String: Int].self, forKey: .windowEpochs) ?? [:]
    }

    /// Ten minutes of activity = one observation block.
    public static let observationBlock: TimeInterval = 600

    /// Open an observation of the app. Legacy rows without an epoch are stamped with the CURRENT one (they
    /// start ageing from now, not from their 2026 dates). The clock ticks only for a SUBSTANTIAL scene (a
    /// lone popup-reveal upsert or a text-only frame is evidence of nothing's absence) and at most once per
    /// `observationBlock`; the observed window's own counter ticks with it. Returns whether it ticked.
    mutating func beginIngest(now: Date, window: String?, substantial: Bool) -> Bool {
        for i in objects.indices where objects[i].lastSeenEpoch == nil { objects[i].lastSeenEpoch = ingestEpoch }
        for i in groups.indices where groups[i].lastSeenEpoch == nil { groups[i].lastSeenEpoch = ingestEpoch }
        for i in transitions.indices where transitions[i].lastObservedEpoch == nil { transitions[i].lastObservedEpoch = ingestEpoch }
        guard substantial else { return false }
        let ticks = lastEpochAdvance.map { now.timeIntervalSince($0) >= Self.observationBlock } ?? true
        if ticks {
            ingestEpoch += 1
            lastEpochAdvance = now
            if let window { windowEpochs[window, default: 0] += 1 }
        } else if let window, windowEpochs[window] == nil {
            windowEpochs[window] = 1                       // first look at a new window counts once
        }
        return ticks
    }

    /// The value a row seen NOW in `window` is stamped with (that window's counter, else the brain clock).
    func stamp(for window: String?) -> Int { window.flatMap { windowEpochs[$0] } ?? ingestEpoch }

    /// How many observations of the row's OWN window have passed since it was last seen (0 when that window
    /// has not been looked at since — absence of looking is not evidence of absence).
    func unseenFor(window: String?, stamp: Int?) -> Int {
        let current = window.flatMap { windowEpochs[$0] } ?? ingestEpoch
        return max(0, current - (stamp ?? current))
    }
}

public extension UIBrain {
    /// Known SWITCH slots: members of any group where at least one member has shown on/off state —
    /// membership implies nature, so every slot in a switch column is a switch. Used by detection to
    /// classify a lone LIVE square at a known slot (memory classifies live pixels, never fabricates).
    func switchMemberSlots() -> [(pos: [Double], anchorKey: String)] {
        var out: [(pos: [Double], anchorKey: String)] = []
        for g in groups {
            let members = g.memberAnchors.compactMap { key in objects.first { $0.anchorKey == key } }
            guard members.contains(where: { $0.statesSeen.keys.contains("on") || $0.statesSeen.keys.contains("off") })
            else { continue }
            for m in members where m.boundsTypical.count == 4 {
                out.append((m.boundsTypical, m.anchorKey))
            }
        }
        return out
    }

    /// One-line affordance summary of an anchor's TRUSTED transitions: evidence ≥ 2 for state effects
    /// (one observation is never causality — a toggle can flip for other reasons), but a MENU REVEAL
    /// counts from its first sighting: the differ literally watched the menu cluster appear after the
    /// click, menus are deterministic, and hiding "opens: … Desktop …" for a second confirmation cost a
    /// live agent a 44s scroll hunt for an item a dropdown held (measured, Creative Cloud).
    func does(anchorKey: String) -> String? {
        Self.doesSummary(transitions.filter { $0.anchorKey == anchorKey })
    }

    /// Shared tail of `does` so enrich can feed it pre-bucketed transitions (one grouping pass per
    /// scene instead of a full-ledger scan per element).
    static func doesSummary(_ ts: [UITransition]) -> String? {
        let trusted = ts.filter { $0.evidence >= 2 || $0.effect.hasPrefix("menuOpened:") }
        guard !trusted.isEmpty else { return nil }
        var byTrigger: [String: UITransition] = [:]
        for t in trusted where (byTrigger[t.trigger]?.evidence ?? 0) < t.evidence { byTrigger[t.trigger] = t }
        return byTrigger.keys.sorted().map { "\($0): \(SceneDiff.summary(byTrigger[$0]!.effect))" }.joined(separator: " · ")
    }

    /// REVEALERS of a hidden target: anchors whose learned click/right-click REVEALED a set of elements
    /// containing `target` (menuOpened / elementsAppeared items). This is how "reach" knows that
    /// 'Desktop' is not something to scroll to but something a dropdown hides — the difference between
    /// a 1s guided answer and a 44s blind scroll hunt (measured). Any evidence counts: the items were
    /// OBSERVED, not inferred.
    func revealers(of target: String) -> [(label: String, trigger: String, boundsTypical: [Double], items: [String])] {
        let tNorm = KnowledgeText.normalize(target)
        guard !tNorm.isEmpty else { return [] }
        var out: [(label: String, trigger: String, boundsTypical: [Double], items: [String])] = []
        var seenAnchors: Set<String> = []
        for t in transitions.sorted(by: { $0.evidence > $1.evidence }) {
            // ONLY menuOpened. `elementsAppeared` is pane-repaint noise: navigating a tab or hovering a
            // nav item repaints the content area, so EVERY label in it "appeared" — the brain then
            // believed "Marketplace reveals Illustrator" and "Files reveals Premiere", and reach handed
            // the model that nonsense as guidance (measured, both in one session).
            guard t.effect.hasPrefix("menuOpened:") else { continue }
            let itemsStr = t.effect.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let items = itemsStr.split(separator: "|").map(String.init)
            // A menu item is a SHORT NAME, and the target must BE one — not merely resemble one. Fuzzy
            // matching made "Premiere" hit a card description that happens to contain the word.
            guard items.allSatisfy({ $0.count <= 40 }) else { continue }   // long items ⇒ a repainted pane, not a menu
            let hit = items.contains { $0.count <= 30 && KnowledgeText.normalize($0) == tNorm }
            guard hit, !seenAnchors.contains(t.anchorKey),
                  let o = objects.first(where: { $0.anchorKey == t.anchorKey }) else { continue }
            seenAnchors.insert(t.anchorKey)
            // An UNLABELED anchor still reveals (measured: Creative Cloud's platform dropdown anchored
            // without a name) — return its typical bounds so the caller can point at the LIVE element
            // sitting there, and the remembered ITEMS so the model can name the menu's contents even
            // when the revealer itself can't be pointed at.
            out.append((o.label.isEmpty ? (o.aliases.first ?? "") : o.label, t.trigger, o.boundsTypical, items))
        }
        // Named revealers first — a label beats a position hint when both exist.
        return out.sorted { !$0.label.isEmpty && $1.label.isEmpty }
    }

    /// NAMING OPPORTUNITIES (B5): unlabeled anchors ranked by VALUE TO THIS USER — usage beats
    /// existence. Score = how often it's seen + how much interaction knowledge it carries + whether
    /// it belongs to a known structure. The LLM names the ten things the user actually touches, not
    /// the four hundred they never will.
    func namingOpportunities(limit: Int = 10) -> [(anchor: UIObjectAnchor, score: Int, context: String)] {
        objects.filter { $0.label.isEmpty }
            .map { o -> (UIObjectAnchor, Int, String) in
                let ts = transitions.filter { $0.anchorKey == o.anchorKey }
                let score = o.seenCount + ts.reduce(0) { $0 + $1.evidence * 3 } + (o.groupID != nil ? 5 : 0)
                var ctx: [String] = []
                if let gid = o.groupID, let g = groups.first(where: { $0.id == gid }),
                   let ord = g.memberAnchors.firstIndex(of: o.anchorKey) {
                    ctx.append("group \(g.name ?? g.axis) #\(ord + 1)/\(g.memberAnchors.count) (\(g.sharedKind)s)")
                }
                if !o.statesSeen.isEmpty { ctx.append("states " + o.statesSeen.keys.sorted().joined(separator: "/")) }
                for t in ts.sorted(by: { $0.evidence > $1.evidence }).prefix(2) {
                    ctx.append("\(t.trigger)→\(SceneDiff.summary(t.effect)) ×\(t.evidence)")
                }
                if !o.aliases.isEmpty { ctx.append("aka " + o.aliases.prefix(3).joined(separator: "/")) }
                ctx.append(String(format: "at %.2f,%.2f", o.boundsTypical.first ?? 0,
                                  o.boundsTypical.count > 1 ? o.boundsTypical[1] : 0))
                return (o, score, ctx.joined(separator: "; "))
            }
            .sorted { a, b in
                // Explicit statements: the ternary form made the type-checker time out on Swift 6.3.
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.anchorKey < b.0.anchorKey
            }
            .prefix(limit).map { $0 }
    }

    /// ENRICH a scene with what the brain knows (B1+B3). Read-only annotation — positions stay live:
    /// - a matched element gains its sibling-group tag ("Destinations#3" — ordinal identity)
    /// - and its trusted affordances ("click: toggles") learned by the differ
    /// - an UNLABELED element whose anchor carries a remembered name inherits it, marked `recalled`
    ///   (its id is rebuilt from the recalled label so act targeting + scene tokens stay stable).
    /// - `app`: the bundle this brain belongs to, for READ-HIT ACCOUNTING. One `enrich` is ONE
    ///   consultation (the brain is asked once and answers for the whole frame — the per-element matches
    ///   are its internals, not separate questions), and it counts as USEFUL only when the answer changed
    ///   the scene the agent reads: a recalled name, an ordinal tag or an affordance line that was not
    ///   there before. This is the audit's open question about the largest store — 10,340 anchors, 20%
    ///   named, and nothing recorded what any of it was worth. Pass nil to enrich without accounting.
    func enrich(_ elements: [SceneElement], app: String? = nil,
                memory: LocatorMemory = .shared) -> [SceneElement] {
        // One index + one bucketing pass for the whole scene — per-element scans over a learning
        // brain are exactly what made describe_scene degrade as knowledge grew.
        let index = BrainIndex(self)
        let groupByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let transitionsByAnchor = Dictionary(grouping: transitions, by: \.anchorKey)
        let enriched = elements.map { el in
            guard el.kind == "control" || el.kind == "icon", el.pos.count == 4 else { return el }
            let det = BrainDetection(kind: el.kind, label: (el.unlabeled == true) ? "" : el.label,
                                     pos: el.pos, state: el.state)
            guard case .found(let key) = BrainMatcher.match(det, in: self, index: index),
                  let o = index.indexByKey[key].map({ objects[$0] }) else { return el }
            var out = el
            if let gid = o.groupID, let g = groupByID[gid],
               let ord = g.memberAnchors.firstIndex(of: key) {
                out.group = "\(g.name ?? g.axis)#\(ord + 1)"
            }
            out.does = Self.doesSummary(transitionsByAnchor[key] ?? [])
            if el.unlabeled == true, !o.label.isEmpty {
                out.label = o.label
                out.unlabeled = nil
                out.recalled = true
                out.id = ObservedObject.makeIdentityKey(role: nil, identifier: nil, text: o.label, boundsNormalized: el.pos)
            }
            return out
        }
        if let app {
            memory.noteConsultedRead(.brain, app: app)
            // The counterfactual IS the returned scene: if nothing in it differs, the brain answered and
            // the agent reads exactly what perception alone produced. One array compare, gate-only.
            if memory.readHitsEnabled, enriched != elements { memory.noteUsefulRead(.brain, app: app) }
        }
        return enriched
    }
}

/// One detection from a scene, in brain-input form (window-normalized coordinates).
public struct BrainDetection: Sendable, Equatable {
    public var kind: String     // "control" | "icon" | "text"
    public var label: String    // "" when unlabeled
    public var pos: [Double]    // normalized [x,y,w,h]
    public var state: String?

    public init(kind: String, label: String, pos: [Double], state: String? = nil) {
        self.kind = kind; self.label = label; self.pos = pos; self.state = state
    }
}

/// Prebuilt lookups over ONE brain snapshot, so matching costs a dictionary probe instead of full
/// scans. This is the fix for the measured describe_scene decay (4.3→10.4s on identical calls):
/// `match` ran up to four `objects.filter` passes PER ELEMENT, each re-running
/// `KnowledgeText.normalize` on every label and alias — ~millions of normalizations on a 500-element
/// Pro Tools scene against 1270 anchors, growing as the brain learns. Build once per scene/ingest;
/// the index is only valid for the exact snapshot it was built from.
public struct BrainIndex: Sendable {
    let byNormLabel: [String: [Int]]   // normalized label OR alias → object indices (each object once)
    let llmByKind: [String: [Int]]     // labelSource=="llm" anchors, by kind (they hold positional pull)
    let indexByKey: [String: Int]      // anchorKey → object index

    public init(_ brain: UIBrain) {
        var byLabel: [String: [Int]] = [:], llm: [String: [Int]] = [:]
        var byKey: [String: Int] = Dictionary(minimumCapacity: brain.objects.count)
        for (i, o) in brain.objects.enumerated() {
            byKey[o.anchorKey] = i
            // A set per object: an object with three alias spellings of one normal must land in the
            // bucket ONCE, or a lone anchor would look like two ambiguous siblings.
            var normals: Set<String> = []
            let ln = KnowledgeText.normalize(o.label)
            if !ln.isEmpty { normals.insert(ln) }
            for a in o.aliases {
                let an = KnowledgeText.normalize(a)
                if !an.isEmpty { normals.insert(an) }
            }
            for n in normals { byLabel[n, default: []].append(i) }
            if o.labelSource == "llm" { llm[o.kind, default: []].append(i) }
        }
        byNormLabel = byLabel; llmByKind = llm; indexByKey = byKey
    }
}

/// Pure anchor matching + ingestion. The matching CASCADE (cheap→rich, unique-accept throughout —
/// two near-equal candidates mean NO match, mirroring the relocation engine's lesson that
/// near-identical siblings break naive matching):
///   1. label+kind, position within tolerance (exactly one → hit; several → ambiguous, skip)
///   2. unique label+kind app-wide (the object moved — window resize)
///   3. GROUP ORDINAL: position matches exactly one known member slot of a same-kind group
///   4. no match → a new anchor is created (ingest) — never a forced merge
public enum BrainMatcher {
    /// `ambiguous` carries the tied candidates: the ingest may mark them PRESENT (they are on screen) even
    /// though it must not pick one (found by review: co-visible near-identical siblings never got
    /// stamped, aged as absent, and churned through decay every 13 observations).
    public enum Match: Equatable { case found(String), ambiguous([String]), none }

    static func center(_ pos: [Double]) -> (x: Double, y: Double) {
        guard pos.count == 4 else { return (0, 0) }
        return (pos[0] + pos[2] / 2, pos[1] + pos[3] / 2)
    }
    static func dist(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// Same object CANNOT differ wildly in size — a wide logo+text composite must never merge with a
    /// narrow switch that shares its row's name (measured failure: Facebook composite w=0.073 fused
    /// with the Facebook switch w=0.025 via the unique-label fallback). Factor 2.2 tolerates window
    /// resizes; beyond that it's a different object.
    static func sizeCompatible(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == 4, b.count == 4, a[2] > 0, a[3] > 0, b[2] > 0, b[3] > 0 else { return true }
        let wr = max(a[2], b[2]) / min(a[2], b[2]), hr = max(a[3], b[3]) / min(a[3], b[3])
        return wr <= 2.2 && hr <= 2.2
    }

    /// `index` MUST be built from this exact `brain` snapshot (nil builds one — fine for one-off
    /// calls). `excluding` hides already-claimed anchors from every tier, which is how ingest keeps
    /// its each-anchor-claimable-once rule without copying the whole object array per detection.
    public static func match(_ d: BrainDetection, in brain: UIBrain,
                             index prebuilt: BrainIndex? = nil,
                             excluding claimed: Set<String> = []) -> Match {
        guard d.pos.count == 4 else { return .none }
        let index = prebuilt ?? BrainIndex(brain)
        func alive(_ i: Int) -> UIObjectAnchor? {
            claimed.isEmpty || !claimed.contains(brain.objects[i].anchorKey) ? brain.objects[i] : nil
        }
        let c = center(d.pos)
        // Tolerance scales with the element (rows sit ~2 element-heights apart; must not span two).
        let tol = max(max(d.pos[2], d.pos[3]) * 1.25, 0.02)
        let dn = KnowledgeText.normalize(d.label)
        let byLabel = dn.isEmpty ? [] : (index.byNormLabel[dn] ?? []).compactMap(alive).filter { o in
            o.kind == d.kind && sizeCompatible(d.pos, o.boundsTypical)
        }
        if !dn.isEmpty {
            let near = byLabel.filter { dist(center($0.boundsTypical), c) <= tol }
            if near.count == 1 { return .found(near[0].anchorKey) }
            if near.count > 1 { return .ambiguous(near.map(\.anchorKey)) }   // two same-label siblings both in reach
            // (unique-label fallback moves BELOW the llm-position tier — see there)
        }
        // LLM-NAMED anchors hold their POSITION claim (the ledger's point: a deliberate name STICKS
        // to the object even when captions churn, misread, or vanish). Scoped to labelSource=="llm"
        // only — giving every anchor positional pull is exactly the cross-screen alias-poisoning bug
        // ("TikTok aka Downloads"); llm names are few, deliberate, and worth the bounded risk.
        let llmNear = (index.llmByKind[d.kind] ?? []).compactMap(alive).filter { o in
            sizeCompatible(d.pos, o.boundsTypical) && dist(center(o.boundsTypical), c) <= tol
        }
        if llmNear.count == 1 { return .found(llmNear[0].anchorKey) }
        if llmNear.count > 1 { return .ambiguous(llmNear.map(\.anchorKey)) }
        if !dn.isEmpty {
            if byLabel.count == 1 { return .found(byLabel[0].anchorKey) } // unique in app → it moved
            // several same-label siblings, none near → fall through to ordinal
        }
        // ORDINAL rescue — for UNLABELED/jittered members only. A detection whose label CONTRADICTS the
        // slot's member is a DIFFERENT SCREEN's object at the same place (measured failure: the Import
        // sidebar's "Downloads" was absorbed into the TikTok switch anchor) — never a match.
        for g in brain.groups where g.sharedKind == d.kind {
            let cell = max(g.cellSize.first ?? 0, g.cellSize.count > 1 ? g.cellSize[1] : 0)
            let slotTol = max(cell * 0.8, 0.015)
            let hits = g.memberAnchors.compactMap { key in index.indexByKey[key].flatMap(alive) }
                .filter { o in
                    guard dist(center(o.boundsTypical), c) <= slotTol, sizeCompatible(d.pos, o.boundsTypical)
                    else { return false }
                    let on = KnowledgeText.normalize(o.label)
                    return dn.isEmpty || on.isEmpty || dn == on
                        || o.aliases.contains { KnowledgeText.normalize($0) == dn }
                }
            if hits.count == 1 { return .found(hits[0].anchorKey) }
            if hits.count > 1 { return .ambiguous(hits.map(\.anchorKey)) }
        }
        return .none
    }
}

/// Geometric sibling-group detection + the ingest pass that keeps the brain current.
public enum BrainUpdater {
    public struct IngestStats: Equatable, Sendable {
        public var created = 0, updated = 0, skippedAmbiguous = 0
        public init() {}
    }

    /// Ingest one scene's detections: anchor-match interactive elements (control/icon), update or
    /// create anchors, then detect + persist sibling groups. Texts are used only for group naming.
    /// `window` is the captured window's title letters-family (`KnowledgeText.letters`): forgetting is
    /// scoped to it. nil = unscoped (CLI, single-detection upserts) — aged by the brain-wide clock.
    public static func ingest(_ detections: [BrainDetection], into brain: inout UIBrain, now: Date,
                              window: String? = nil) -> IngestStats {
        var stats = IngestStats()
        // Slivers (scrollbar thumbs, dividers) MOVE — each position would spawn a fresh anchor
        // (measured: one thumb became 12 stacked anchors forming a fake column). Not anchorable.
        let interactive = detections.filter {
            ($0.kind == "control" || $0.kind == "icon")
                && $0.pos.count == 4 && $0.pos[2] >= 0.006 && $0.pos[3] >= 0.004
        }
        let texts = detections.filter { $0.kind == "text" }
        var anchorFor: [Int: String] = [:]   // interactive index → anchorKey
        // A SUBSTANTIAL scene (≥3 interactive detections) is an observation; a lone reveal upsert is not.
        let advanced = brain.beginIngest(now: now, window: window, substantial: interactive.count >= 3)
        let epoch = brain.ingestEpoch
        let stamp = brain.stamp(for: window)

        // Match against the PRE-SCENE baseline, each anchor claimable once: two detections in the
        // same scene are distinct objects by definition (they coexist on screen) — the second same-label
        // sibling must never merge into the anchor its neighbor just claimed (or just created).
        // (`excluding:` hides claimed anchors — this loop used to COPY the whole object array per
        // detection to express the same rule.)
        let baseline = brain
        let index = BrainIndex(baseline)
        var claimed = Set<String>()

        for (i, d) in interactive.enumerated() {
            switch BrainMatcher.match(d, in: baseline, index: index, excluding: claimed) {
            case .found(let key):
                guard let oi = brain.objects.firstIndex(where: { $0.anchorKey == key }) else { continue }
                brain.objects[oi].seenCount += 1
                brain.objects[oi].lastSeen = now
                brain.objects[oi].lastSeenEpoch = stamp
                brain.objects[oi].window = window ?? brain.objects[oi].window
                brain.objects[oi].boundsTypical = d.pos
                if let s = d.state { brain.objects[oi].statesSeen[s, default: 0] += 1 }
                let dn = KnowledgeText.normalize(d.label)
                if !dn.isEmpty {
                    // LEDGER rule: an llm-assigned name is immutable to observation — variants only
                    // collect as aliases. Observed names upgrade/alias as before.
                    if brain.objects[oi].label.isEmpty, brain.objects[oi].labelSource != "llm" {
                        brain.objects[oi].label = d.label                                      // label upgrade
                        brain.objects[oi].labelSource = "observed"
                    } else if KnowledgeText.normalize(brain.objects[oi].label) != dn,
                              !brain.objects[oi].aliases.contains(where: { KnowledgeText.normalize($0) == dn }) {
                        brain.objects[oi].aliases.append(d.label)                              // jitter variant
                    }
                }
                anchorFor[i] = key; claimed.insert(key); stats.updated += 1
            case .ambiguous(let keys):
                stats.skippedAmbiguous += 1   // never guess between near-identical siblings —
                // but they ARE on screen: mark presence (no seenCount, no bounds, no label, no claim).
                for key in keys {
                    guard let oi = brain.objects.firstIndex(where: { $0.anchorKey == key }) else { continue }
                    brain.objects[oi].lastSeen = now
                    brain.objects[oi].lastSeenEpoch = stamp
                    brain.objects[oi].window = window ?? brain.objects[oi].window
                }
            case .none:
                var fresh = UIObjectAnchor(kind: d.kind, label: d.label, boundsTypical: d.pos,
                                           firstSeen: now, lastSeen: now, lastSeenEpoch: stamp, window: window)
                if let s = d.state { fresh.statesSeen[s] = 1 }
                anchorFor[i] = fresh.anchorKey
                brain.objects.append(fresh)
                stats.created += 1
            }
        }

        // A popup-verified REVEAL whose revealer is on screen is live knowledge, not a coincidence going
        // stale (does()/revealers() trust it at evidence 1). Other evidence-1 edges keep ageing: a control
        // that is always on screen must not immortalize a redraw that once coincided with a click.
        for i in brain.transitions.indices
        where brain.transitions[i].effect.hasPrefix("menuOpened:") && claimed.contains(brain.transitions[i].anchorKey) {
            brain.transitions[i].lastObservedEpoch = epoch
        }

        // Sibling groups from THIS scene, persisted across scenes. Merge is gated on member overlap
        // AND cell-size AND axis-position (measured failure: the Import sidebar's rows unioned into
        // the Destinations switch column); after every merge, members that no longer align are EVICTED.
        for cand in detectGroups(interactive: interactive, texts: texts) {
            let members = cand.memberIndices.compactMap { anchorFor[$0] }
            guard members.count >= 3 else { continue }
            let candAxisPos = cand.memberIndices.compactMap { interactive[$0].pos.count == 4
                ? (cand.axis == "column" ? interactive[$0].pos[0] : interactive[$0].pos[1]) : nil }
            let candMedian = median(candAxisPos)
            let gi = brain.groups.firstIndex { g in
                guard g.axis == cand.axis, g.sharedKind == cand.sharedKind,
                      Double(Set(g.memberAnchors).intersection(members).count)
                          >= 0.5 * Double(min(g.memberAnchors.count, members.count)),
                      cellsSimilar(g.cellSize, cand.cellSize) else { return false }
                let cell = cand.axis == "column" ? (cand.cellSize.first ?? 0.02) : (cand.cellSize.count > 1 ? cand.cellSize[1] : 0.02)
                return abs(axisPosition(of: g, in: brain) - candMedian) <= max(2 * cell, 0.03)
            }
            if let gi {
                let union = Set(brain.groups[gi].memberAnchors).union(members)
                brain.groups[gi].memberAnchors = ordered(anchors: union, in: brain, axis: cand.axis)
                brain.groups[gi].cellSize = cand.cellSize
                brain.groups[gi].seenCount += 1
                brain.groups[gi].lastSeen = now
                brain.groups[gi].lastSeenEpoch = epoch
                if brain.groups[gi].name == nil { brain.groups[gi].name = cand.name }
                evictMisaligned(groupIndex: gi, in: &brain)
                assignGroupID(brain.groups[gi].id, to: brain.groups[gi].memberAnchors, in: &brain)
            } else {
                let g = SiblingGroup(axis: cand.axis, memberAnchors: members, sharedKind: cand.sharedKind,
                                     cellSize: cand.cellSize, name: cand.name, lastSeen: now, lastSeenEpoch: epoch)
                assignGroupID(g.id, to: members, in: &brain)
                brain.groups.append(g)
            }
        }
        if advanced { decay(&brain, now: now) }   // forget once per observation block, never per frame
        return stats
    }

    /// What the brain keeps, measured in OBSERVATIONS of the app (`ingestEpoch`), not in days.
    public struct Retention: Sendable {
        /// A seen-once object unseen for this many observations was a transient (menu item, misread, hover reveal).
        public var transientIngests = 12
        /// Any observed object unseen for this many observations: the app updated, the UI moved on.
        public var staleIngests = 150
        /// Evidence-1 transitions unseen this long were coincidences; all transitions die at `transitionStaleIngests`.
        public var coincidenceIngests = 30
        public var transitionStaleIngests = 300
        /// The only date rule left — a backstop for something not observed in a year.
        public var backstopDays = 365.0
        public static let standard = Retention()
        public init() {}
    }

    /// DECAY — the brain forgets like it learns: by EVIDENCE, and evidence of absence is "the app was
    /// observed N more times and this was not there". Never by the calendar: an app that is not looked
    /// at does not forget (measured 2026-09-06 — wall-clock decay wiped the pro-app brains while the
    /// watcher slept; the apps nobody used kept everything). An observation is a ten-minute block of
    /// activity (`UIBrain.observationBlock`), scoped to the WINDOW that was looked at. Rules:
    /// - a seen-ONCE object unseen for `transientIngests` observations of its window → drop;
    /// - anything unseen for `staleIngests` observations (or `backstopDays` of wall clock) → drop;
    /// - a PROTECTED object (a name someone assigned) is never dropped and is outside the cap;
    /// - hard cap `maxObjects` on the UNPROTECTED rows: keep the most-established (seenCount, recency);
    /// - groups lose dropped members; under 3 members or unseen `staleIngests` → dissolve;
    /// - transitions: evidence-1 unseen `coincidenceIngests` → drop — EXCEPT popup-verified menu reveals,
    ///   which `does()`/`revealers()` trust at evidence 1 and which are refreshed whenever their revealer
    ///   is on screen; all unseen `transitionStaleIngests` → drop.
    /// Rows never stamped (legacy, or a brain that never ingested) count as seen now.
    public static func decay(_ brain: inout UIBrain, now: Date, maxObjects: Int = 3000, retention r: Retention = .standard) {
        let epoch = brain.ingestEpoch
        let backstop = now.addingTimeInterval(-r.backstopDays * 86400)
        let snapshot = brain
        var objects = brain.objects.filter { o in
            if o.isProtected { return true }
            let unseenFor = snapshot.unseenFor(window: o.window, stamp: o.lastSeenEpoch)
            if o.lastSeen < backstop { return false }
            if unseenFor >= r.staleIngests { return false }
            if o.seenCount <= 1 && unseenFor >= r.transientIngests { return false }
            return true
        }
        let protected = objects.filter(\.isProtected)
        var unprotected = objects.filter { !$0.isProtected }
        if unprotected.count > maxObjects {
            unprotected = Array(unprotected.sorted { a, b in
                a.seenCount != b.seenCount ? a.seenCount > b.seenCount : a.lastSeen > b.lastSeen
            }.prefix(maxObjects))
            let keptKeys = Set(protected.map(\.anchorKey) + unprotected.map(\.anchorKey))
            objects = objects.filter { keptKeys.contains($0.anchorKey) }   // original order, cap applied
        }
        let kept = Set(objects.map(\.anchorKey))
        brain.objects = objects
        brain.groups = brain.groups.compactMap { g in
            var g = g
            g.memberAnchors = g.memberAnchors.filter { kept.contains($0) }
            let unseenFor = max(0, epoch - (g.lastSeenEpoch ?? epoch))
            guard g.memberAnchors.count >= 3, unseenFor < r.staleIngests, g.lastSeen >= backstop else {
                for key in g.memberAnchors {
                    if let i = brain.objects.firstIndex(where: { $0.anchorKey == key }) { brain.objects[i].groupID = nil }
                }
                return nil
            }
            return g
        }
        brain.transitions = brain.transitions.filter { t in
            guard kept.contains(t.anchorKey), t.lastObserved >= backstop else { return false }
            let unseenFor = max(0, epoch - (t.lastObservedEpoch ?? epoch))
            if unseenFor >= r.transitionStaleIngests { return false }
            let trustedReveal = t.effect.hasPrefix("menuOpened:")
            return !(t.evidence <= 1 && !trustedReveal && unseenFor >= r.coincidenceIngests)
        }
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }

    static func cellsSimilar(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == 2, b.count == 2, a[0] > 0, a[1] > 0, b[0] > 0, b[1] > 0 else { return true }
        return max(a[0], b[0]) / min(a[0], b[0]) <= 1.35 && max(a[1], b[1]) / min(a[1], b[1]) <= 1.35
    }

    /// A group's position along its alignment axis (median member x for a column, y for a row).
    static func axisPosition(of g: SiblingGroup, in brain: UIBrain) -> Double {
        median(g.memberAnchors.compactMap { key in
            brain.objects.first { $0.anchorKey == key }.flatMap {
                $0.boundsTypical.count == 4 ? (g.axis == "column" ? $0.boundsTypical[0] : $0.boundsTypical[1]) : nil
            }
        })
    }

    /// Drop members whose CURRENT bounds no longer align with the group's axis — impostors absorbed
    /// before the merge gates existed, or objects that genuinely moved away. Heals polluted stores.
    static func evictMisaligned(groupIndex gi: Int, in brain: inout UIBrain) {
        let g = brain.groups[gi]
        let axisPos = axisPosition(of: g, in: brain)
        let cell = g.axis == "column" ? (g.cellSize.first ?? 0.02) : (g.cellSize.count > 1 ? g.cellSize[1] : 0.02)
        let tol = max(0.6 * cell, 0.012)
        var kept: [String] = [], evicted: [String] = []
        for key in g.memberAnchors {
            guard let o = brain.objects.first(where: { $0.anchorKey == key }), o.boundsTypical.count == 4 else { continue }
            let p = g.axis == "column" ? o.boundsTypical[0] : o.boundsTypical[1]
            let sizeOK = BrainMatcher.sizeCompatible(o.boundsTypical, [0, 0, g.cellSize.first ?? 0, g.cellSize.count > 1 ? g.cellSize[1] : 0])
            if abs(p - axisPos) <= tol && sizeOK { kept.append(key) } else { evicted.append(key) }
        }
        brain.groups[gi].memberAnchors = kept
        for key in evicted {
            if let i = brain.objects.firstIndex(where: { $0.anchorKey == key }) { brain.objects[i].groupID = nil }
        }
    }

    /// NAME an anchor deliberately (B5 ledger, source "llm"). The old observed label survives as an
    /// alias so perception can still match it. Returns false if the anchor doesn't exist.
    @discardableResult
    public static func setName(_ name: String, anchorKey: String, into brain: inout UIBrain, now: Date) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = brain.objects.firstIndex(where: { $0.anchorKey == anchorKey }) else { return false }
        let old = brain.objects[i].label
        if !old.isEmpty, KnowledgeText.normalize(old) != KnowledgeText.normalize(trimmed),
           !brain.objects[i].aliases.contains(where: { KnowledgeText.normalize($0) == KnowledgeText.normalize(old) }) {
            brain.objects[i].aliases.append(old)
        }
        brain.objects[i].label = trimmed
        brain.objects[i].labelSource = "llm"
        brain.objects[i].lastSeen = now
        brain.objects[i].lastSeenEpoch = brain.stamp(for: brain.objects[i].window)
        return true
    }

    /// Record a learned transition (B2). Same (anchor, trigger, effect) → evidence++; consumers must
    /// only TRUST transitions at evidence >= 2 (one click coinciding with a redraw is not causality).
    public static func recordTransition(anchorKey: String, trigger: String, effect: String,
                                        into brain: inout UIBrain, now: Date) -> Int {
        if let i = brain.transitions.firstIndex(where: {
            $0.anchorKey == anchorKey && $0.trigger == trigger && $0.effect == effect
        }) {
            brain.transitions[i].evidence += 1
            brain.transitions[i].lastObserved = now
            brain.transitions[i].lastObservedEpoch = brain.ingestEpoch
            return brain.transitions[i].evidence
        }
        brain.transitions.append(UITransition(anchorKey: anchorKey, trigger: trigger, effect: effect, lastObserved: now,
                                              lastObservedEpoch: brain.ingestEpoch))
        return 1
    }

    static func assignGroupID(_ id: UUID, to anchors: [String], in brain: inout UIBrain) {
        for key in anchors {
            if let i = brain.objects.firstIndex(where: { $0.anchorKey == key }) { brain.objects[i].groupID = id }
        }
    }

    static func ordered(anchors: Set<String>, in brain: UIBrain, axis: String) -> [String] {
        anchors.compactMap { key in brain.objects.first { $0.anchorKey == key } }
            .sorted { a, b in
                let (ac, bc) = (BrainMatcher.center(a.boundsTypical), BrainMatcher.center(b.boundsTypical))
                return axis == "column" ? ac.y < bc.y : ac.x < bc.x
            }
            .map(\.anchorKey)
    }

    public struct GroupCandidate: Equatable, Sendable {
        public var axis: String
        public var memberIndices: [Int]     // into the `interactive` array, ordered along the axis
        public var sharedKind: String
        public var cellSize: [Double]
        public var name: String?
    }

    /// Pure geometry: >=3 same-kind elements, same size (±25%), sharing a left edge (column) or top
    /// edge (row). Regular spacing is deliberately NOT required — section headers interleave real
    /// columns (measured: Premiere's Destinations gaps alternate 72px and 168px). Columns win ties.
    public static func detectGroups(interactive: [BrainDetection], texts: [BrainDetection]) -> [GroupCandidate] {
        var out: [GroupCandidate] = []
        var taken = Set<Int>()
        for axis in ["column", "row"] {
            let pool = interactive.indices.filter { !taken.contains($0) && interactive[$0].pos.count == 4 }
            var used = Set<Int>()
            for i in pool where !used.contains(i) {
                let a = interactive[i].pos
                var cluster = [i]
                for j in pool where j != i && !used.contains(j) {
                    let b = interactive[j].pos
                    guard interactive[j].kind == interactive[i].kind,
                          sameSize(a, b) else { continue }
                    let aligned = axis == "column"
                        ? abs(b[0] - a[0]) <= 0.6 * max(a[2], 0.004)
                        : abs(b[1] - a[1]) <= 0.6 * max(a[3], 0.004)
                    if aligned { cluster.append(j) }
                }
                guard cluster.count >= 3 else { continue }
                cluster.sort { axis == "column" ? interactive[$0].pos[1] < interactive[$1].pos[1]
                                                : interactive[$0].pos[0] < interactive[$1].pos[0] }
                used.formUnion(cluster); taken.formUnion(cluster)
                out.append(GroupCandidate(axis: axis, memberIndices: cluster,
                                          sharedKind: interactive[i].kind,
                                          cellSize: [a[2], a[3]],
                                          name: groupName(axis: axis, first: interactive[cluster[0]].pos, texts: texts)))
            }
        }
        return out
    }

    static func sameSize(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == 4, b.count == 4, a[2] > 0, a[3] > 0 else { return false }
        return abs(b[2] - a[2]) <= 0.25 * a[2] && abs(b[3] - a[3]) <= 0.25 * a[3]
    }

    /// The group's name: nearest header text above (column) / left of (row) the first member.
    static func groupName(axis: String, first: [Double], texts: [BrainDetection]) -> String? {
        guard first.count == 4 else { return nil }
        let fc = BrainMatcher.center(first)
        var best: (String, Double)?
        for t in texts where t.pos.count == 4 && t.label.count >= 2 && ElementGrouper.isNameworthy(t.label) {
            let tc = BrainMatcher.center(t.pos)
            let gap: Double
            if axis == "column" {
                gap = first[1] - (t.pos[1] + t.pos[3])                      // text ABOVE the first member
                guard gap >= 0, gap <= 0.12, abs(tc.x - fc.x) <= 0.25 else { continue }
            } else {
                gap = first[0] - (t.pos[0] + t.pos[2])                      // text LEFT of the first member
                guard gap >= 0, gap <= 0.15, abs(tc.y - fc.y) <= 0.05 else { continue }
            }
            if best == nil || gap < best!.1 { best = (t.label, gap) }
        }
        return best?.0
    }
}

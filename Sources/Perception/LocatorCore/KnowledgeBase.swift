import Foundation
import CoreGraphics

/// How an observed object's information was obtained: `ax` from the Accessibility tree (high trust,
/// structured), `cv` from pixels/OCR (for opaque apps where AX returns one group).
public enum ObjectSource: String, Codable, Sendable { case ax, cv }

/// What the SYSTEM CURSOR over an element implies about it — a near-free affordance/TYPE hint sampled while
/// the user hovers. Valuable on opaque apps (Pro Tools/Premiere) where AX gives no role: an I-beam still
/// says "editable text", a pointing hand says "link/button". Best-effort: an unrecognized or custom cursor
/// is `.unknown` — never a wrong guess that would poison the relocation cascade's role hint.
public enum CursorAffordance: String, Codable, Sendable {
    case arrow       // generic — no special affordance
    case text        // I-beam → editable text
    case link        // pointing hand → link / clickable
    case resize      // resize arrows → pane divider / handle
    case drag        // open/closed hand → draggable
    case disabled    // not-allowed → disabled target
    case busy        // wait / spinning
    case crosshair   // crosshair → canvas / precision tool
    case unknown     // unrecognized / custom cursor (no guess)
}

/// One UI object observed inside a window — a lightweight HYPOTHESIS in the knowledge base. We persist
/// text + normalized bounds + (optionally) an edge-hash only; NO pixel crop is stored by default
/// (privacy + storage). A retrieval hit is always re-verified live through the relocation cascade before
/// any click — the KB never answers with a directly-clickable coordinate. Identity-over-appearance is
/// preserved: matching is digit-sensitive at the verify layer, so "Audio 6" is never confused with "Audio 7".
public struct ObservedObject: Codable, Equatable, Sendable {
    /// Stable key for dedup/merge within an app (role + identifier + normalized text + a coarse position
    /// bucket — see ``makeIdentityKey``). The "open problem #3" key-of-record; intentionally pluggable.
    public var identityKey: String
    public var selfText: String?            // AX title/description/value, or OCR text
    public var role: String?                // AX role (e.g. "AXButton"); nil for a pure-CV object
    public var source: ObjectSource
    public var boundsNormalized: [Double]    // [x, y, w, h] as fractions of the window (0..1), latest seen
    public var edgeHash: String?            // optional perceptual hash (CV identity / change detection)
    public var affordance: CursorAffordance? // optional cursor-shape type hint sampled while hovering (ambient watcher)
    public var firstSeen: Date
    public var lastSeen: Date
    public var observationCount: Int

    public init(identityKey: String, selfText: String?, role: String?, source: ObjectSource,
                boundsNormalized: [Double], edgeHash: String? = nil, affordance: CursorAffordance? = nil,
                firstSeen: Date, lastSeen: Date, observationCount: Int = 1) {
        self.identityKey = identityKey
        self.selfText = selfText
        self.role = role
        self.source = source
        self.boundsNormalized = boundsNormalized
        self.edgeHash = edgeHash
        self.affordance = affordance
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.observationCount = observationCount
    }

    /// The normalized bounds as a CGRect (fractions of the window).
    public var boundsRect: CGRect {
        guard boundsNormalized.count == 4 else { return .null }
        return CGRect(x: boundsNormalized[0], y: boundsNormalized[1], width: boundsNormalized[2], height: boundsNormalized[3])
    }

    /// Coarse match score of this object against a free-text query (0 = no match). The KB ranking is a
    /// cheap CANDIDATE selector only; final correctness is the cascade's digit-sensitive verify. TOKEN-based
    /// (never raw-substring on the normalized concatenation — that made a lone "5" match "Audio 25"): exact
    /// normalized equality (3) > one token-set fully contains the other (2) > token-overlap fraction (0..1).
    public func matchScore(query: String) -> Double {
        selfText.map { KnowledgeText.matchScore(query: query, against: $0) } ?? 0
    }

    /// Build a stable identity key. Text-bearing objects key on (role + normalized text); text-less ones
    /// (icons) fall back to a coarse 10×10 position bucket so the same icon-slot dedups across frames
    /// without one-pixel jitter spawning duplicates.
    public static func makeIdentityKey(role: String?, identifier: String?, text: String?, boundsNormalized: [Double]) -> String {
        if let id = identifier, !id.isEmpty { return "id:\(id)" }
        let r = role ?? "?"
        let t = KnowledgeText.normalize(text ?? "")
        if !t.isEmpty { return "\(r)|\(t)" }
        let bx = boundsNormalized.count == 4 ? Int((boundsNormalized[0] * 10).rounded()) : 0
        let by = boundsNormalized.count == 4 ? Int((boundsNormalized[1] * 10).rounded()) : 0
        return "\(r)|@\(bx),\(by)"
    }
}

/// Text helpers for KB matching — a minimal, dependency-free normalizer (the relocation cascade has its
/// own digit-sensitive identity matcher; this is only the coarse candidate selector).
public enum KnowledgeText {
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    public static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !$0.isEmpty }
    }
    /// Coarse, digit-sensitive lexical score of `query` vs `text` (0 = none). Exact normalized equality (3) >
    /// one token-set fully contains the other (2) > token-overlap fraction (0..1). The KB's candidate
    /// selector; final correctness is the cascade's live verify. Shared by ObservedObject + MenuCommand.
    public static func matchScore(query: String, against text: String) -> Double {
        let qn = normalize(query), tn = normalize(text)
        guard !qn.isEmpty, !tn.isEmpty else { return 0 }
        if qn == tn { return 3 }
        let qt = Set(tokens(query)), tt = Set(tokens(text))
        guard !qt.isEmpty, !tt.isEmpty else { return 0 }
        if qt == tt { return 2.5 }                                    // same tokens, any order ("New Track" ≡ "Track … New")
        if qt.isSubset(of: tt) || tt.isSubset(of: qt) { return 2 }
        return Double(qt.intersection(tt).count) / Double(qt.count)
    }
    /// Lowercased LETTERS only (digits/punctuation/space dropped) — the title "family", stable across a
    /// volatile counter/version/timecode in the title ("Edit: GAME • v4" and "… v5" → "editgamev").
    public static func letters(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter }) }
}

/// Stable identity of a UI window-STATE — built only from things that DON'T move with live data or scroll,
/// so the same screen is ONE node (not a new node per meter tick, timecode frame, playhead step, or scroll
/// position). Three channels: the title family, the AX role-multiset signature, and the numeric-stripped
/// static label set. (No pixel hash: the playhead/scroll slide pixels; structure+labels are robust.)
public struct StateFingerprint: Codable, Equatable, Sendable {
    public var titleBucket: String      // letters-only window title family
    public var structureSig: String     // sorted "role:log2(count)" multiset; "" if opaque/thin
    public var labelSet: [String]       // sorted, numeric-stripped static labels (scroll-invariant for lists)

    public init(titleBucket: String, structureSig: String, labelSet: [String]) {
        self.titleBucket = titleBucket; self.structureSig = structureSig; self.labelSet = labelSet
    }

    /// Same UI state? Title family is a hard gate; then either the AX structure signature matches OR the
    /// label sets are ≥ `minLabelJaccard` similar. Scrolling a list changes WHICH "Audio N" show, but the
    /// numeric-stripped labels ({audio, wave, …}) and the log2-bucketed role counts don't — so scroll, and
    /// animated meters/timecode (volatile numeric tokens, dropped), keep it one state.
    public func matches(_ other: StateFingerprint, minLabelJaccard: Double = 0.6) -> Bool {
        guard titleBucket == other.titleBucket else { return false }
        if !structureSig.isEmpty, structureSig == other.structureSig { return true }
        let a = Set(labelSet), b = Set(other.labelSet)
        let union = a.union(b)
        guard !union.isEmpty else { return true }
        return Double(a.intersection(b).count) / Double(union.count) >= minLabelJaccard
    }

    /// Build from a harvested window: its title + the observed objects (roles → structure, texts → labels).
    public static func make(title: String, objects: [ObservedObject]) -> StateFingerprint {
        StateFingerprint(titleBucket: KnowledgeText.letters(title),
                         structureSig: structureSignature(roles: objects.map { $0.role ?? "cv" }),
                         labelSet: canonicalLabels(objects.compactMap(\.selfText)))
    }

    /// Role multiset with counts log2-bucketed (so 12 vs 15 rows after a scroll don't fork) → a sorted,
    /// process-STABLE joined string (NOT Swift's per-run-randomized hashValue).
    static func structureSignature(roles: [String]) -> String {
        var counts: [String: Int] = [:]
        for r in roles { counts[r, default: 0] += 1 }
        return counts.keys.sorted().map { "\($0):\(Int(log2(Double(counts[$0]! + 1))))" }.joined(separator: "|")
    }

    /// Static labels: tokens that contain a letter and are ≥2 chars; pure numeric/timecode/version tokens
    /// (volatile) are dropped. Sorted + deduped → canonical, scroll- and data-invariant.
    static func canonicalLabels(_ texts: [String]) -> [String] {
        var set = Set<String>()
        for t in texts {
            for tok in KnowledgeText.tokens(t) where tok.count >= 2 && tok.contains(where: \.isLetter) {
                set.insert(tok)
            }
        }
        return set.sorted()
    }
}

/// All objects observed for one window of one app (keyed conceptually by the window-title pattern).
public struct WindowInventory: Codable, Equatable, Sendable {
    public var windowTitlePattern: String
    public var objects: [ObservedObject]
    public var lastObserved: Date
    /// Identity of the UI state these objects belong to (nil for pre-P2b inventories, which match by title).
    public var fingerprint: StateFingerprint?

    public init(windowTitlePattern: String, objects: [ObservedObject] = [], lastObserved: Date,
                fingerprint: StateFingerprint? = nil) {
        self.windowTitlePattern = windowTitlePattern
        self.objects = objects
        self.lastObserved = lastObserved
        self.fingerprint = fingerprint
    }

    /// Merge a fresh observation in: known objects (by identityKey) update their bounds to the latest,
    /// gain any newly-available text/role/hash, bump count + lastSeen; unknown objects are appended.
    public mutating func merge(_ incoming: [ObservedObject], now: Date) {
        var byKey = Dictionary(objects.map { ($0.identityKey, $0) }, uniquingKeysWith: { a, _ in a })
        for obj in incoming {
            if var existing = byKey[obj.identityKey] {
                existing.boundsNormalized = obj.boundsNormalized
                existing.selfText = existing.selfText ?? obj.selfText
                existing.role = existing.role ?? obj.role
                existing.edgeHash = obj.edgeHash ?? existing.edgeHash
                existing.affordance = obj.affordance ?? existing.affordance
                existing.lastSeen = now
                existing.observationCount += 1
                byKey[obj.identityKey] = existing
            } else {
                var fresh = obj; fresh.firstSeen = now; fresh.lastSeen = now; fresh.observationCount = 1
                byKey[obj.identityKey] = fresh
            }
        }
        // Deterministic order: most-recently-seen first, then by key.
        objects = byKey.values.sorted { ($0.lastSeen, $0.identityKey) > ($1.lastSeen, $1.identityKey) }
        lastObserved = now
    }

    /// Ranked candidates for a query: positive match score, best first; ties broken by how often the
    /// object has been seen (more-observed = more stable), then identityKey for determinism.
    public func candidates(for query: String, limit: Int = 8) -> [ObservedObject] {
        objects.map { ($0, $0.matchScore(query: query)) }
            .filter { $0.1 > 0 }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.observationCount != b.0.observationCount { return a.0.observationCount > b.0.observationCount }
                return a.0.identityKey < b.0.identityKey
            }
            .prefix(limit).map(\.0)
    }
}

/// The knowledge base for one app: its observed windows.
public struct AppKnowledge: Codable, Equatable, Sendable {
    public var bundleID: String
    public var windows: [WindowInventory]
    /// Menu-bar commands enumerated read-only by the P3 auto-explorer (additive; absent in pre-P3 JSON).
    public var menuCommands: [MenuCommand]
    /// The UI BRAIN: anchored objects + sibling groups + learned transitions (docs/UI_BRAIN_PLAN.md).
    public var brain: UIBrain
    /// PROCEDURAL memory: named replayable verb sequences learned from successful use (Routes.swift).
    public var routes: [Route]

    public init(bundleID: String, windows: [WindowInventory] = [], menuCommands: [MenuCommand] = [],
                brain: UIBrain = UIBrain(), routes: [Route] = []) {
        self.bundleID = bundleID
        self.windows = windows
        self.menuCommands = menuCommands
        self.brain = brain
        self.routes = routes
    }

    // Custom decode so older per-app JSON (no `menuCommands`/no `windows`/no `brain`) still loads —
    // synthesized Decodable would throw on the absent key; encode stays synthesized.
    private enum CodingKeys: String, CodingKey { case bundleID, windows, menuCommands, brain, routes }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        windows = try c.decodeIfPresent([WindowInventory].self, forKey: .windows) ?? []
        menuCommands = try c.decodeIfPresent([MenuCommand].self, forKey: .menuCommands) ?? []
        brain = try c.decodeIfPresent(UIBrain.self, forKey: .brain) ?? UIBrain()
        routes = try c.decodeIfPresent([Route].self, forKey: .routes) ?? []
    }

    /// Merge an observation of one window-STATE into this app's knowledge. When a `fingerprint` is given,
    /// objects merge into the matching STATE (robust to scroll/title-counter churn); otherwise they match by
    /// window title (the pre-P2b path). A first fingerprint backfills onto a title-matched inventory.
    public mutating func observe(windowTitlePattern: String, objects: [ObservedObject], now: Date,
                                 fingerprint: StateFingerprint? = nil) {
        let i: Int? = fingerprint.map { fp in
            windows.firstIndex { ($0.fingerprint?.matches(fp) ?? false) || ($0.fingerprint == nil && $0.windowTitlePattern == windowTitlePattern) }
        } ?? windows.firstIndex { $0.windowTitlePattern == windowTitlePattern }
        if let i {
            windows[i].merge(objects, now: now)
            if windows[i].fingerprint == nil { windows[i].fingerprint = fingerprint }
        } else {
            var inv = WindowInventory(windowTitlePattern: windowTitlePattern, lastObserved: now, fingerprint: fingerprint)
            inv.merge(objects, now: now)
            windows.append(inv)
        }
    }

    public var objectCount: Int { windows.reduce(0) { $0 + $1.objects.count } }
}

/// Allowlist of app bundle IDs Locator may observe / act in. `allowAll` (DEFAULT TRUE) makes every app
/// allowed with no per-app opt-in — the frictionless default the user asked for. Flip it off with
/// `locator kb restrict` to return to explicit, default-deny opt-in (then the per-app sets below apply).
/// NOTE: relaxing this does NOT relax the OTHER gates — destructive-label refusal, secure-field refusal,
/// live re-perception (never a cached coordinate), and ambiguity refusal all still hold.
public struct Allowlist: Codable, Equatable, Sendable {
    /// Master switch: everything allowed (observe AND act). Default true. `kb restrict` sets it false.
    public var allowAll: Bool
    /// DESTRUCTIVE actions (delete/send/quit… in any language) — refused by default even when the app is
    /// otherwise allowed. `kb allow-destructive` flips this ON so the user can have the agent delete/send
    /// when they ask. USER-only (the LLM can't set it), default FALSE — undoable damage stays deliberate.
    public var allowDestructive: Bool
    public var bundleIDs: Set<String>                 // pinned for OBSERVE when allowAll is off
    /// Pinned for the ACTIVE step when allowAll is off. Also used, even under allowAll, as the "which app"
    /// hint when an ACTION names no app (so a single pinned app is the unambiguous no-arg target).
    public var activeBundleIDs: Set<String>
    public init(bundleIDs: Set<String> = [], activeBundleIDs: Set<String> = [], allowAll: Bool = true, allowDestructive: Bool = false) {
        self.bundleIDs = bundleIDs; self.activeBundleIDs = activeBundleIDs
        self.allowAll = allowAll; self.allowDestructive = allowDestructive
    }
    public func allows(_ bundleID: String) -> Bool { allowAll || bundleIDs.contains(bundleID) }
    public func allowsActive(_ bundleID: String) -> Bool { allowAll || activeBundleIDs.contains(bundleID) }

    private enum CodingKeys: String, CodingKey { case bundleIDs, activeBundleIDs, allowAll, allowDestructive }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        bundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .bundleIDs) ?? []
        activeBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .activeBundleIDs) ?? []
        // Absent in old JSON → true: existing installs adopt the frictionless default automatically.
        allowAll = try c.decodeIfPresent(Bool.self, forKey: .allowAll) ?? true
        // Destructive stays OFF unless explicitly opted in (safe default, even for old installs).
        allowDestructive = try c.decodeIfPresent(Bool.self, forKey: .allowDestructive) ?? false
    }
}

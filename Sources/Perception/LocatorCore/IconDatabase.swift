import Foundation
import CoreGraphics

/// One distinct ICON (a non-text UI element) collected from an app, for manual labeling and later LLM
/// grounding. Deduped by PERCEPTUAL HASH within an app — the same glyph is ONE record, regardless of where
/// it appears. Stores a crop (so it can be shown for labeling) + a human `label` + provenance. The eventual
/// payoff: at runtime an LLM gets `label` + position instead of pixels.
public struct IconRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var edgeHash: String                 // perceptual hash — the dedup key (Hamming-compared)
    public var label: String?                   // human label (nil/"" = unlabeled)
    public var cropRef: String                  // bare filename of the crop PNG (under icons/crops/)
    public var sizePx: CGSize                   // crop pixel size
    public var boundsNormalizedSample: [Double] // a representative [x,y,w,h] (0..1 of the captured region), latest seen
    public var neighbors: [String]              // nearby OCR text where it was seen — CONTEXT for (auto-)labeling
    public var observationCount: Int
    public var firstSeen: Date
    public var lastSeen: Date

    public init(id: UUID, edgeHash: String, label: String? = nil, cropRef: String, sizePx: CGSize,
                boundsNormalizedSample: [Double], neighbors: [String] = [], observationCount: Int = 1,
                firstSeen: Date, lastSeen: Date) {
        self.id = id; self.edgeHash = edgeHash; self.label = label; self.cropRef = cropRef
        self.sizePx = sizePx; self.boundsNormalizedSample = boundsNormalizedSample; self.neighbors = neighbors
        self.observationCount = observationCount; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }

    // Custom decode so icon JSON written before `neighbors` existed still loads (→ []). Encode stays synthesized.
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        edgeHash = try c.decode(String.self, forKey: .edgeHash)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        cropRef = try c.decode(String.self, forKey: .cropRef)
        sizePx = try c.decode(CGSize.self, forKey: .sizePx)
        boundsNormalizedSample = try c.decode([Double].self, forKey: .boundsNormalizedSample)
        neighbors = try c.decodeIfPresent([String].self, forKey: .neighbors) ?? []
        observationCount = try c.decode(Int.self, forKey: .observationCount)
        firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
    }

    public var isLabeled: Bool { label?.isEmpty == false }
}

/// All icons collected for one app, keyed conceptually by bundle ID.
public struct AppIcons: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var icons: [IconRecord]

    public init(bundleID: String, appName: String, icons: [IconRecord] = []) {
        self.bundleID = bundleID; self.appName = appName; self.icons = icons
    }

    public var labeledCount: Int { icons.filter(\.isLabeled).count }

    /// Index of an existing icon within `maxDistance` Hamming of `edgeHash` (the dedup match), or nil if
    /// this icon is new. First-match wins (icons of one app are visually distinct enough).
    public func matchIndex(edgeHash: String, maxDistance: Int) -> Int? {
        icons.firstIndex { IconHash.distance($0.edgeHash, edgeHash) <= maxDistance }
    }

    /// The label of the NEAREST LABELED icon within `maxDistance` — the scene-labeling match. Distinct
    /// from `matchIndex` (peek's dedup) on purpose: the DB accumulates near-duplicate UNLABELED entries
    /// (every hover re-render hashes slightly differently), and first-match-any let an unlabeled sibling
    /// absorb the match, so the user's label never surfaced (measured: Ron labeled Slack's 'call' icon and
    /// the scene kept showing "(unlabeled)"). Only labeled icons can NAME something — search just those,
    /// nearest wins.
    public func bestLabel(edgeHash: String, maxDistance: Int) -> String? {
        var best: (label: String, dist: Int)?
        for icon in icons where icon.isLabeled {
            let d = IconHash.distance(icon.edgeHash, edgeHash)
            if d <= maxDistance, d < (best?.dist ?? Int.max) { best = (icon.label!, d) }
        }
        return best?.label
    }
}

/// Hamming distance between two hex-encoded perceptual hashes (e.g. the Sobel edge hash). Compares nibble
/// by nibble, so it works on any equal-length hex string. Returns `Int.max` on a length mismatch (never a
/// false "identical").
public enum IconHash {
    public static func distance(_ a: String, _ b: String) -> Int {
        guard a.count == b.count else { return Int.max }
        var dist = 0
        for (ca, cb) in zip(a, b) {
            let na = ca.hexDigitValue ?? 0, nb = cb.hexDigitValue ?? 0
            dist += (na ^ nb).nonzeroBitCount
        }
        return dist
    }
}

/// Atomic, per-app persistence for the icon database: one `<bundleID>.json` under the icons dir, with crop
/// PNGs under `crops/`. Local-only; kept out of Time Machine (the crops are screen pixels).
public struct IconStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// Where crop PNGs live (`icons/crops/`). The collector writes here via `CropStore(directory:)`.
    public var cropsDir: URL { directory.appendingPathComponent("crops", isDirectory: true) }

    private func url(for bundleID: String) -> URL {
        directory.appendingPathComponent("\(bundleID.replacingOccurrences(of: "/", with: "_")).json")
    }

    public func load(bundleID: String) -> AppIcons? {
        let u = url(for: bundleID)
        guard let data = try? Data(contentsOf: u) else { return nil }
        return try? DescriptorStore.makeDecoder().decode(AppIcons.self, from: data)
    }

    public func save(_ app: AppIcons) throws {
        try FileManager.default.createDirectory(at: cropsDir, withIntermediateDirectories: true)
        try DescriptorStore.makeEncoder().encode(app).write(to: url(for: app.bundleID), options: [.atomic])
    }

    /// Bundle IDs with a collected icon set.
    public func bundleIDs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

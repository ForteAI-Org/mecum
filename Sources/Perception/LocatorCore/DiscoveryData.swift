import Foundation

/// The capability-discovery store's DATA model + a read-only view — in LocatorCore so the frontend
/// (which surfaces learned capabilities in its preload) can read it in-process, while the classifier
/// that WRITES it lives in the engine (it needs the capability catalog). This is the "apply" side of
/// the watcher→discovery loop: things the user does BY HAND that an API verb can do directly.
public struct DiscoveryItem: Codable, Equatable, Sendable {
    public var app: String
    public var label: String
    public var verb: String?     // set for KNOWN (an API verb does this action)
    public var count: Int
    public var lastSeen: Date
    public init(app: String, label: String, verb: String?, count: Int, lastSeen: Date) {
        self.app = app; self.label = label; self.verb = verb; self.count = count; self.lastSeen = lastSeen
    }
}

public struct DiscoveryData: Codable, Equatable, Sendable {
    public var known: [DiscoveryItem]   // hand-actions an API verb already covers
    public var gaps: [DiscoveryItem]    // hand-actions with no verb yet (build candidates)
    public init(known: [DiscoveryItem] = [], gaps: [DiscoveryItem] = []) { self.known = known; self.gaps = gaps }
}

/// Read-only access to discovery.json (beside the behavior log). Consumers that only SURFACE learned
/// capabilities use this; the writer (DiscoveryStore, engine-side) owns classification.
public enum DiscoveryReader {
    public static func load(directory: URL) -> DiscoveryData {
        let url = directory.appendingPathComponent("discovery.json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? dec.decode(DiscoveryData.self, from: $0) } ?? DiscoveryData()
    }

    public static func loadDefault() -> DiscoveryData {
        guard let dir = try? DescriptorPaths.behaviorDir() else { return DiscoveryData() }
        return load(directory: dir)
    }

    /// Top KNOWN verb-mappings by frequency — the user's habitual hand-actions that can be automated.
    /// Deduped to one row per verb (the most-used label for that verb) so the surfacing stays short.
    /// `minCount` is a HONESTY FLOOR: only surface an action done at least this many times, so "you often
    /// do these" is truthful and a single incidental click never becomes an automation nudge (review nit).
    public static func knownTopByVerb(_ limit: Int, minCount: Int = 2) -> [DiscoveryItem] {
        var bestForVerb: [String: DiscoveryItem] = [:]
        for it in loadDefault().known {
            guard let v = it.verb else { continue }
            if let cur = bestForVerb[v], cur.count >= it.count { continue }
            bestForVerb[v] = it
        }
        return bestForVerb.values.filter { $0.count >= minCount }.sorted { $0.count > $1.count }.prefix(limit).map { $0 }
    }
}

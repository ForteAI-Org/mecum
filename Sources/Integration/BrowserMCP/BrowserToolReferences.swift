import BrowserCore

/// BrowserToolReferences binds short model-facing IDs to one connection's adapter IDs.
/// Only the latest observation per tab is retained. Consumed IDs are never reused in this host.
struct BrowserToolReferences {
    private var tabs: [String: String] = [:]
    private var aliases: [String: String] = [:]
    private var observations: [String: (alias: String, native: String)] = [:]
    private var nextTab = 0
    private var nextObservation = 0

    mutating func tab(_ native: String) -> String {
        if let alias = aliases[native] { return alias }
        nextTab += 1
        let alias = "t\(nextTab)"
        aliases[native] = alias
        tabs[alias] = native
        return alias
    }

    func resolveTab(_ alias: String) throws -> String {
        guard let native = tabs[alias] else {
            throw BrowserFailure(.staleReference, "Unknown tab reference. Use browser_tabs and copy its exact id; do not guess a tab.")
        }
        return native
    }

    mutating func observe(_ native: String, tab: String) -> String {
        nextObservation += 1
        let alias = "s\(nextObservation)"
        observations[tab] = (alias, native)
        return alias
    }

    func resolveObservation(_ alias: String?, tab: String) throws -> String {
        guard let observation = observations[tab], observation.alias == alias else {
            throw BrowserFailure(.staleReference, "Use the latest observation id and ref for this tab. If unavailable, call browser_snapshot; do not replay an earlier action.")
        }
        return observation.native
    }

    mutating func invalidate(_ tab: String) { observations.removeValue(forKey: tab) }

    mutating func remove(_ tab: String) {
        invalidate(tab)
        if let alias = aliases.removeValue(forKey: tab) { tabs.removeValue(forKey: alias) }
    }

    mutating func retainTabs(_ current: Set<String>) {
        for native in Array(aliases.keys) where !current.contains(native) { remove(native) }
    }

    mutating func clear() {
        tabs.removeAll()
        aliases.removeAll()
        observations.removeAll()
    }
}

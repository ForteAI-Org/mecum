import Foundation

/// Chrome multi-profile awareness for the AGENT's cloned browser (Ron: "automatically use those
/// profiles with no logins"). Chrome's `Local State` JSON maps profile DIRECTORY names ("Profile 1")
/// to the human identity ("Ron", ron@forte-ai.com); parsing it lets `locator chrome launch
/// --profile ron` resolve by NAME the way a person thinks of it. Pure file parsing — no Chrome APIs.
public enum ChromeProfiles {
    public struct Profile: Sendable, Equatable {
        public let dir: String      // "Default", "Profile 1", …
        public let name: String     // "Ron"
        public let account: String  // "ron@forte-ai.com" (empty if not signed in)
        public init(dir: String, name: String, account: String) {
            self.dir = dir; self.name = name; self.account = account
        }
    }

    public static func parse(localState: Data) -> [Profile] {
        guard let obj = (try? JSONSerialization.jsonObject(with: localState)) as? [String: Any],
              let cache = (obj["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { dir, v -> Profile? in
            guard let info = v as? [String: Any] else { return nil }
            return Profile(dir: dir,
                           name: (info["name"] as? String) ?? dir,
                           account: (info["user_name"] as? String) ?? "")
        }.sorted { $0.dir < $1.dir }
    }

    public static func load(dataDir: URL) -> [Profile] {
        (try? Data(contentsOf: dataDir.appendingPathComponent("Local State"))).map(parse(localState:)) ?? []
    }

    /// The agent Chrome's data dir — cloned from the real one by `locator chrome clone`.
    public static var agentDataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fflow/chrome-agent")
    }

    /// Open (or add a window to) the agent Chrome for a profile, debuggable on `port`. Chrome's
    /// singleton lock forwards to the running instance, so repeated calls = more profile windows,
    /// ONE instance, one port. Shared by the CLI (`locator chrome launch`) and the MCP tool
    /// (`web_open_profile`) — one launch recipe, not two.
    public static func openAgentWindow(profileDir: String?, url: String? = nil, port: Int = 9222) throws {
        var args = ["-na", "Google Chrome", "--args",
                    "--user-data-dir=\(agentDataDir.path)",
                    "--remote-debugging-port=\(port)",
                    "--no-first-run", "--no-default-browser-check"]
        if let d = profileDir { args.append("--profile-directory=\(d)") }
        if let u = url { args.append(u) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }

    /// Unique-accept resolution on name/account/dir: exact (case-insensitive) wins outright, otherwise
    /// substring — 0 or 2+ hits come back as-is so the caller can be honest about the ambiguity.
    public static func match(_ query: String, in profiles: [Profile]) -> [Profile] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        if let exact = profiles.first(where: {
            $0.name.lowercased() == q || $0.account.lowercased() == q || $0.dir.lowercased() == q
        }) { return [exact] }
        return profiles.filter {
            $0.name.lowercased().contains(q) || $0.account.lowercased().contains(q) || $0.dir.lowercased().contains(q)
        }
    }
}

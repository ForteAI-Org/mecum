//
//  Allowlist.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// Allowlist names the applications the engine may observe and act in. `allowAll` is the default:
/// every application, no opt-in. Turning it off returns to explicit per-application opt-in, where
/// observing and acting are separate grants. Relaxing this relaxes no other gate: destructive
/// refusal, ambiguity refusal and live re-perception all still hold.
public struct Allowlist: Sendable, Equatable, Codable {

    /// Master switch for observing and acting everywhere.
    public var allowAll: Bool
    /// Whether destructive labels (delete, send, quit, in any language) may be acted on at all. A
    /// person sets this, never a model; the default is off.
    public var allowDestructive: Bool
    /// Applications pinned for observing when `allowAll` is off.
    public var bundleIDs: Set<String>
    /// Applications pinned for acting when `allowAll` is off. Also the "which application" hint when
    /// an action names none.
    public var activeBundleIDs: Set<String>

    public init(
        bundleIDs       : Set<String> = [],
        activeBundleIDs : Set<String> = [],
        allowAll        : Bool = true,
        allowDestructive: Bool = false
    ) {
        self.bundleIDs        = bundleIDs
        self.activeBundleIDs  = activeBundleIDs
        self.allowAll         = allowAll
        self.allowDestructive = allowDestructive
    }

    public func allows(_ bundleID: String) -> Bool { allowAll || bundleIDs.contains(bundleID) }

    public func allowsActive(_ bundleID: String) -> Bool { allowAll || activeBundleIDs.contains(bundleID) }

    private enum CodingKeys: String, CodingKey { case bundleIDs, activeBundleIDs, allowAll, allowDestructive }

    /// Older JSON without the switches reads as allow-all and destructive-off.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleIDs       : try c.decodeIfPresent(Set<String>.self, forKey: .bundleIDs) ?? [],
            activeBundleIDs : try c.decodeIfPresent(Set<String>.self, forKey: .activeBundleIDs) ?? [],
            allowAll        : try c.decodeIfPresent(Bool.self, forKey: .allowAll) ?? true,
            allowDestructive: try c.decodeIfPresent(Bool.self, forKey: .allowDestructive) ?? false
        )
    }
}

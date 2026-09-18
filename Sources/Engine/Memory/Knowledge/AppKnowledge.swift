//
//  AppKnowledge.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation

/// AppKnowledge is everything remembered about one application: its observed window states, its
/// menu commands, the brain of anchored objects and learned transitions, and its earned routes.
///
/// Older per-application JSON that lacks a section still decodes; each absent key reads as empty.
public struct AppKnowledge: Sendable, Equatable, Codable {

    public var bundleID: String
    public var windows: [WindowInventory]
    public var menuCommands: [MenuCommand]
    public var brain: UIBrain
    public var routes: [Route]

    public init(
        bundleID    : String,
        windows     : [WindowInventory] = [],
        menuCommands: [MenuCommand] = [],
        brain       : UIBrain = UIBrain(),
        routes      : [Route] = []
    ) {
        self.bundleID     = bundleID
        self.windows      = windows
        self.menuCommands = menuCommands
        self.brain        = brain
        self.routes       = routes
    }

    private enum CodingKeys: String, CodingKey { case bundleID, windows, menuCommands, brain, routes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleID    : try c.decode(String.self, forKey: .bundleID),
            windows     : try c.decodeIfPresent([WindowInventory].self, forKey: .windows) ?? [],
            menuCommands: try c.decodeIfPresent([MenuCommand].self, forKey: .menuCommands) ?? [],
            brain       : try c.decodeIfPresent(UIBrain.self, forKey: .brain) ?? UIBrain(),
            routes      : try c.decodeIfPresent([Route].self, forKey: .routes) ?? []
        )
    }

    /// Merges an observation of one window state. With a fingerprint, objects merge into the matching
    /// state, robust to scrolling and title counters; without one they match by window title. A first
    /// fingerprint backfills onto a title-matched inventory.
    public mutating func observe(
        windowTitlePattern: String,
        objects           : [ObservedObject],
        now               : Date,
        fingerprint       : StateFingerprint? = nil
    ) {
        let index: Int? = fingerprint.map { print in
            windows.firstIndex {
                ($0.fingerprint?.matches(print) ?? false)
                    || ($0.fingerprint == nil && $0.windowTitlePattern == windowTitlePattern)
            }
        } ?? windows.firstIndex { $0.windowTitlePattern == windowTitlePattern }
        if let index {
            windows[index].merge(objects, now: now)
            if windows[index].fingerprint == nil { windows[index].fingerprint = fingerprint }
        } else {
            var inventory = WindowInventory(windowTitlePattern: windowTitlePattern, lastObserved: now,
                                            fingerprint: fingerprint)
            inventory.merge(objects, now: now)
            windows.append(inventory)
        }
    }

    public var objectCount: Int { windows.reduce(0) { $0 + $1.objects.count } }
}

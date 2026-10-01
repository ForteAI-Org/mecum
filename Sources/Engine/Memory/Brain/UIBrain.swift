//
//  UIBrain.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// UIBrain is the persistent per-application world model layered over per-frame perception:
/// anchored objects, sibling groups, learned transitions, and the observation clock everything
/// forgets by. The brain describes; it never aims. Typical bounds are hints for matching and
/// annotation, and every action re-perceives live.
///
/// All-absent JSON decodes to an empty brain, so a store written before any section existed loads.
public struct UIBrain: Sendable, Equatable, Codable {

    public var objects: [ObjectAnchor]
    public var groups: [SiblingGroup]
    public var transitions: [LearnedTransition]
    /// How many observations this brain has ingested. An application that is not looked at does not
    /// forget: wall-clock decay once wiped three professional applications' brains while the watcher
    /// slept (measured 2026-09-06).
    public var ingestEpoch: Int
    /// When the clock last ticked. One observation is a ten-minute block of activity, not a frame.
    public var lastEpochAdvance: Date?
    /// Per-window observation counters: parses of one window are evidence of absence only for anchors
    /// last seen in that window.
    public var windowEpochs: [String: Int]

    public init(
        objects         : [ObjectAnchor] = [],
        groups          : [SiblingGroup] = [],
        transitions     : [LearnedTransition] = [],
        ingestEpoch     : Int = 0,
        lastEpochAdvance: Date? = nil,
        windowEpochs    : [String: Int] = [:]
    ) {
        self.objects          = objects
        self.groups           = groups
        self.transitions      = transitions
        self.ingestEpoch      = ingestEpoch
        self.lastEpochAdvance = lastEpochAdvance
        self.windowEpochs     = windowEpochs
    }

    private enum CodingKeys: String, CodingKey {
        case objects, groups, transitions, ingestEpoch, lastEpochAdvance, windowEpochs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            objects         : try c.decodeIfPresent([ObjectAnchor].self, forKey: .objects) ?? [],
            groups          : try c.decodeIfPresent([SiblingGroup].self, forKey: .groups) ?? [],
            transitions     : try c.decodeIfPresent([LearnedTransition].self, forKey: .transitions) ?? [],
            ingestEpoch     : try c.decodeIfPresent(Int.self, forKey: .ingestEpoch) ?? 0,
            lastEpochAdvance: try c.decodeIfPresent(Date.self, forKey: .lastEpochAdvance),
            windowEpochs    : try c.decodeIfPresent([String: Int].self, forKey: .windowEpochs) ?? [:]
        )
    }

    /// Ten minutes of activity is one observation block.
    public static let observationBlock: TimeInterval = 600

    // MARK: The observation clock

    /// Opens an observation. Legacy rows without an epoch are stamped with the current one, so they
    /// age from now. The clock ticks only for a substantial scene and at most once per observation
    /// block; the observed window's own counter ticks with it. Returns whether it ticked.
    mutating func beginIngest(now: Date, window: String?, substantial: Bool) -> Bool {
        for i in objects.indices where objects[i].lastSeenEpoch == nil { objects[i].lastSeenEpoch = ingestEpoch }
        for i in groups.indices where groups[i].lastSeenEpoch == nil { groups[i].lastSeenEpoch = ingestEpoch }
        for i in transitions.indices where transitions[i].lastObservedEpoch == nil {
            transitions[i].lastObservedEpoch = ingestEpoch
        }
        guard substantial else { return false }
        let ticks = lastEpochAdvance.map { now.timeIntervalSince($0) >= Self.observationBlock } ?? true
        if ticks {
            ingestEpoch += 1
            lastEpochAdvance = now
            if let window { windowEpochs[window, default: 0] += 1 }
        } else if let window, windowEpochs[window] == nil {
            windowEpochs[window] = 1
        }
        return ticks
    }

    /// The value a row seen now in `window` is stamped with: that window's counter, else the clock.
    func stamp(for window: String?) -> Int { window.flatMap { windowEpochs[$0] } ?? ingestEpoch }

    /// How many observations of the row's own window have passed since it was last seen; 0 when that
    /// window has not been looked at since, because absence of looking is not evidence of absence.
    func unseenFor(window: String?, stamp: Int?) -> Int {
        let current = window.flatMap { windowEpochs[$0] } ?? ingestEpoch
        return max(0, current - (stamp ?? current))
    }

    // MARK: Lookups

    public func object(withKey key: String) -> ObjectAnchor? {
        objects.first { $0.anchorKey == key }
    }

    func objectIndex(withKey key: String) -> Int? {
        objects.firstIndex { $0.anchorKey == key }
    }

    // MARK: Queries

    /// SwitchSlot is a known switch position: a member of a group where some member has shown state.
    public struct SwitchSlot: Sendable, Equatable {
        public let bounds: NormalizedRect
        public let anchorKey: String
    }

    /// Known switch slots. Membership implies nature, so every slot in a switch column is a switch;
    /// detection uses them to classify a lone live square at a known slot, never to fabricate one.
    public func switchMemberSlots() -> [SwitchSlot] {
        var slots: [SwitchSlot] = []
        for group in groups {
            let members = group.memberAnchors.compactMap(object(withKey:))
            guard members.contains(where: \.hasShownSwitchState) else { continue }
            for member in members {
                slots.append(SwitchSlot(bounds: member.boundsTypical, anchorKey: member.anchorKey))
            }
        }
        return slots
    }

    /// A one-line affordance summary of an anchor's trusted transitions, or nil.
    public func does(anchorKey: String) -> String? {
        Self.doesSummary(transitions.filter { $0.anchorKey == anchorKey })
    }

    /// The summary over pre-bucketed transitions: the strongest trusted edge per producer, a stored
    /// click of unknown verb apart from every verb.
    static func doesSummary(_ transitions: [LearnedTransition]) -> String? {
        let trusted = transitions.filter(\.isTrusted)
        guard !trusted.isEmpty else { return nil }
        var byProducer: [String: LearnedTransition] = [:]
        for transition in trusted where (byProducer[transition.producer]?.evidence ?? 0) < transition.evidence {
            byProducer[transition.producer] = transition
        }
        return byProducer.values.sorted { $0.producer < $1.producer }
            .map { "\($0.producer): \($0.summary)" }
            .joined(separator: " · ")
    }

    /// Revealer is an anchor whose learned click or right-click revealed a menu containing a target.
    public struct Revealer: Sendable, Equatable {
        /// The anchor's label, or its first alias, or empty for an unnamed revealer.
        public let label: String
        public let trigger: TransitionTrigger
        public let boundsTypical: NormalizedRect
        public let items: [String]
    }

    /// Revealers of a hidden target: anchors whose learned menu reveal contained `target`. This is how
    /// reach knows a name is behind a dropdown rather than down a scroll. Only menu reveals count: a
    /// pane repaint makes every label in it "appear" and taught the brain nonsense (measured). The
    /// target must be a menu item, not merely resemble one; long items mean a repainted pane.
    public func revealers(of target: String) -> [Revealer] {
        let normalizedTarget = LabelText.normalize(target)
        guard !normalizedTarget.isEmpty else { return [] }
        var revealers: [Revealer] = []
        var seen: Set<String> = []
        for transition in transitions.sorted(by: { $0.evidence > $1.evidence }) {
            guard case .menuOpened(let items)? = transition.sceneEffect else { continue }
            guard items.allSatisfy({ $0.count <= 40 }) else { continue }
            let hit = items.contains { $0.count <= 30 && LabelText.normalize($0) == normalizedTarget }
            guard hit, !seen.contains(transition.anchorKey), let anchor = object(withKey: transition.anchorKey) else {
                continue
            }
            seen.insert(transition.anchorKey)
            revealers.append(Revealer(
                label        : anchor.label.isEmpty ? (anchor.aliases.first ?? "") : anchor.label,
                trigger      : transition.trigger,
                boundsTypical: anchor.boundsTypical,
                items        : items
            ))
        }
        return revealers.sorted { !$0.label.isEmpty && $1.label.isEmpty }
    }

    /// NamingOpportunity is an unlabeled anchor worth naming, with the context a namer needs.
    public struct NamingOpportunity: Sendable, Equatable {
        public let anchor: ObjectAnchor
        public let score: Int
        public let context: String
    }

    /// Unlabeled anchors ranked by value to this user: how often seen, how much interaction knowledge
    /// they carry, and whether they belong to a known structure. Usage beats existence.
    public func namingOpportunities(limit: Int = 10) -> [NamingOpportunity] {
        objects.filter { $0.label.isEmpty }
            .map { anchor -> NamingOpportunity in
                let edges = transitions.filter { $0.anchorKey == anchor.anchorKey }
                let interaction = edges.reduce(0) { $0 + $1.evidence * 3 }
                let score = anchor.seenCount + interaction + (anchor.groupID != nil ? 5 : 0)
                var context: [String] = []
                if let groupID = anchor.groupID, let group = groups.first(where: { $0.id == groupID }),
                   let ordinal = group.memberAnchors.firstIndex(of: anchor.anchorKey) {
                    let name = group.name ?? group.axis.rawValue
                    let size = group.memberAnchors.count
                    context.append("group \(name) #\(ordinal + 1)/\(size) (\(group.sharedKind.rawValue)s)")
                }
                if !anchor.statesSeen.isEmpty {
                    context.append("states " + anchor.statesSeen.keys.sorted().joined(separator: "/"))
                }
                for edge in edges.sorted(by: { $0.evidence > $1.evidence }).prefix(2) {
                    context.append("\(edge.producer)→\(edge.summary) ×\(edge.evidence)")
                }
                if !anchor.aliases.isEmpty { context.append("aka " + anchor.aliases.prefix(3).joined(separator: "/")) }
                context.append(String(format: "at %.2f,%.2f", anchor.boundsTypical.x, anchor.boundsTypical.y))
                return NamingOpportunity(anchor: anchor, score: score, context: context.joined(separator: "; "))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.anchor.anchorKey < rhs.anchor.anchorKey
            }
            .prefix(limit).map { $0 }
    }
}

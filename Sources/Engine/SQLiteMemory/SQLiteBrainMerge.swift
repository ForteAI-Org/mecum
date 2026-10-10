//
//  SQLiteBrainMerge.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation
import Memory

/// BrainMerge is what an earlier origin's Brain gave an application's Brain in this archive, element by
/// element (`SQLiteBrainRepository.merge`). An anchor, a group or a transition whose identity the
/// application's Brain holds is a proven duplicate: kept as it is, its counts not added to, since the
/// same observations would otherwise count twice. One the Brain lacks is added with its origin's counts,
/// which are its history and never a new confirmation, and ages from now. One that cannot be added as it
/// is (its identity is another application's here, its anchor is not in the Brain, its group lost
/// members) is excluded: it stays in the origin's file, and the origin is not complete. A label proves
/// nothing: two anchors labelled alike under different identities are both kept. An element some text
/// of which the admission withheld says so (`withheld`); a transition whose effect held such a value is
/// excluded, since it would predict the marker.
public struct BrainMerge: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        case anchor, group, transition
    }

    public enum Disposition: String, Sendable, Equatable {
        case added, present, excluded
    }

    public struct Contribution: Sendable, Equatable {
        public let kind: Kind
        public let key: String
        public let disposition: Disposition
        public let withheld: Bool

        public init(kind: Kind, key: String, disposition: Disposition, withheld: Bool = false) {
            self.kind        = kind
            self.key         = key
            self.disposition = disposition
            self.withheld    = withheld
        }
    }

    public let contributions: [Contribution]

    public func count(_ disposition: Disposition) -> Int {
        contributions.filter { $0.disposition == disposition }.count
    }

    /// A transition's identity in a Brain: its anchor, trigger and effect.
    static func key(of transition: LearnedTransition) -> String {
        "\(transition.anchorKey)/\(transition.trigger.rawValue)/\(transition.effect)"
    }

    /// Merges `imported` into `brain`. `heldAnchors` and `heldGroups` name the application each identity
    /// of `imported` already belongs to in the archive, retired ones included; `appID` is this
    /// application's. Into an empty Brain everything comes as it was, its clock with it; into one that
    /// already learned, what is added has no epoch and ages from the Brain's present.
    static func merge(
        _ imported : UIBrain,
        into brain : inout UIBrain,
        appID      : Int64,
        heldAnchors: [String: Int64],
        heldGroups : [String: Int64],
        withheld   : ValueMinimization.BrainWithholding = .init()
    ) -> BrainMerge {
        var contributions: [Contribution] = []
        func note(_ kind: Kind, _ key: String, _ disposition: Disposition) {
            let held = switch kind {
                case .anchor    : withheld.anchors.contains(key)
                case .group     : withheld.groups.contains { $0.uuidString == key }
                case .transition: false
            }
            contributions.append(Contribution(kind: kind, key: key, disposition: disposition, withheld: held))
        }
        let wasEmpty = brain.objects.isEmpty && brain.groups.isEmpty && brain.transitions.isEmpty
        var active = Set(brain.objects.map(\.anchorKey))
        var added: [ObjectAnchor] = []
        for anchor in imported.objects {
            let held = heldAnchors[anchor.anchorKey]
            if active.contains(anchor.anchorKey) || held == appID {
                note(.anchor, anchor.anchorKey, .present)
            } else if held != nil {
                note(.anchor, anchor.anchorKey, .excluded)
            } else {
                var copy = anchor
                if !wasEmpty { copy.lastSeenEpoch = nil }
                added.append(copy)
                active.insert(anchor.anchorKey)
                note(.anchor, anchor.anchorKey, .added)
            }
        }
        let addedKeys    = Set(added.map(\.anchorKey))
        let activeGroups = Set(brain.groups.map(\.id))
        var addedGroups: Set<UUID> = []
        for group in imported.groups {
            let key  = group.id.uuidString
            let held = heldGroups[key]
            if activeGroups.contains(group.id) || held == appID {
                note(.group, key, .present)
            } else if held != nil || !group.memberAnchors.allSatisfy(addedKeys.contains) {
                note(.group, key, .excluded)
            } else {
                var copy = group
                if !wasEmpty { copy.lastSeenEpoch = nil }
                brain.groups.append(copy)
                addedGroups.insert(group.id)
                note(.group, key, .added)
            }
        }
        // An added anchor stays in its group only when the group came with it.
        for index in added.indices {
            if let group = added[index].groupID, !addedGroups.contains(group) { added[index].groupID = nil }
        }
        brain.objects += added
        var transitions = Set(brain.transitions.map(Self.key(of:)))
        for transition in imported.transitions {
            let key = Self.key(of: transition)
            if transitions.contains(key) {
                note(.transition, key, .present)
            } else if !active.contains(transition.anchorKey) {
                note(.transition, key, .excluded)
            } else {
                var copy = transition
                if !wasEmpty { copy.lastObservedEpoch = nil }
                brain.transitions.append(copy)
                transitions.insert(key)
                note(.transition, key, .added)
            }
        }
        for transition in withheld.transitions {
            contributions.append(Contribution(kind: .transition, key: Self.key(of: transition), disposition: .excluded,
                                              withheld: true))
        }
        if wasEmpty {
            brain.ingestEpoch      = imported.ingestEpoch
            brain.lastEpochAdvance = imported.lastEpochAdvance
            brain.windowEpochs     = imported.windowEpochs
        }
        return BrainMerge(contributions: contributions)
    }
}

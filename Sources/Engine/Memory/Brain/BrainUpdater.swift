//
//  BrainUpdater.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// BrainUpdater is the ingest pass that keeps a brain current, and the decay that lets it forget the
/// way it learns: by evidence. Every entry point takes the clock as a value.
public enum BrainUpdater {

    /// IngestStats counts what one ingest did, and names the anchors it accepted for this scene.
    public struct IngestStats: Sendable, Equatable {
        public var created = 0
        public var updated = 0
        public var skippedAmbiguous = 0
        /// One entry per interactive detection the ingest matched or anchored, in detection order.
        /// Each anchor appears at most once, the ingest's own "claimable once per scene" rule; an
        /// ambiguous detection has no entry. Never the brain's other, historical anchors.
        public var accepted: [AcceptedAnchor] = []
        /// The brain's observation clock for the scene's window after the ingest opened, the value
        /// the accepted anchors were stamped with: one block of activity, not one frame.
        public var observationBlock = 0
        /// The instant the ingest was stamped with.
        public var observedAt: Date?
        public init() {}
    }

    /// AcceptedAnchor is one detection of the ingested scene and the anchor it now belongs to, with
    /// the anchor's canonical name and provenance after the ingest.
    public struct AcceptedAnchor: Sendable, Equatable {
        public let anchorKey: String
        public let kind: ElementKind
        /// The anchor's canonical label, empty when it has none.
        public let label: String
        public let labelSource: LabelSource?
        /// What this frame read for the detection.
        public let detectedLabel: String
        /// True when this ingest created the anchor.
        public let isNew: Bool
    }

    /// The smallest normalized size an anchor may have; slivers (scrollbar thumbs, dividers) move and
    /// each position would spawn a fresh anchor (measured: one thumb became a fake column).
    static let minimumAnchorWidth = 0.006
    static let minimumAnchorHeight = 0.004

    /// Ingests one scene's detections: matches interactive elements to anchors, updates or creates
    /// them, then detects and persists sibling groups. Texts name groups only. `window` is the
    /// captured window's title letters family; forgetting is scoped to it, nil is unscoped.
    public static func ingest(
        _ detections: [BrainDetection],
        into brain  : inout UIBrain,
        now         : Date,
        window      : String? = nil
    ) -> IngestStats {
        var stats = IngestStats()
        let interactive = detections.filter {
            $0.isInteractive && $0.bounds.width >= minimumAnchorWidth && $0.bounds.height >= minimumAnchorHeight
        }
        let texts = detections.filter { $0.kind == .text }
        var anchorFor: [Int: String] = [:]
        var createdKeys = Set<String>()
        // A substantial scene (three or more interactive detections) is an observation; a lone upsert is not.
        let advanced = brain.beginIngest(now: now, window: window, substantial: interactive.count >= 3)
        let epoch = brain.ingestEpoch
        let stamp = brain.stamp(for: window)

        // Match against the pre-scene baseline, each anchor claimable once: two detections in one scene
        // coexist on screen and are distinct objects by definition.
        let baseline = brain
        let index = BrainIndex(baseline)
        var claimed = Set<String>()

        for (i, detection) in interactive.enumerated() {
            switch BrainMatcher.match(detection, in: baseline, index: index, excluding: claimed) {
                case .found(let key):
                    guard let oi = brain.objectIndex(withKey: key) else { continue }
                    refresh(&brain.objects[oi], with: detection, now: now, stamp: stamp, window: window)
                    anchorFor[i] = key
                    claimed.insert(key)
                    stats.updated += 1
                case .ambiguous(let keys):
                    stats.skippedAmbiguous += 1
                    for key in keys {
                        guard let oi = brain.objectIndex(withKey: key) else { continue }
                        brain.objects[oi].lastSeen      = now
                        brain.objects[oi].lastSeenEpoch = stamp
                        brain.objects[oi].window        = window ?? brain.objects[oi].window
                    }
                case .none:
                    var fresh = ObjectAnchor(
                        kind         : detection.kind,
                        label        : detection.label,
                        boundsTypical: detection.bounds,
                        firstSeen    : now,
                        lastSeen     : now,
                        lastSeenEpoch: stamp,
                        window       : window
                    )
                    if let state = detection.state { fresh.statesSeen[state.rawValue] = 1 }
                    anchorFor[i] = fresh.anchorKey
                    createdKeys.insert(fresh.anchorKey)
                    brain.objects.append(fresh)
                    stats.created += 1
            }
        }

        // A menu reveal whose revealer is on screen is live knowledge; other evidence-one edges keep ageing.
        for i in brain.transitions.indices
        where brain.transitions[i].isMenuReveal && claimed.contains(brain.transitions[i].anchorKey) {
            brain.transitions[i].lastObservedEpoch = epoch
        }

        for candidate in SiblingGroupDetector.detectGroups(interactive: interactive, texts: texts) {
            let members = candidate.memberIndices.compactMap { anchorFor[$0] }
            guard members.count >= 3 else { continue }
            mergeGroup(candidate, members: members, interactive: interactive, into: &brain, now: now, epoch: epoch)
        }
        if advanced { decay(&brain, now: now) }
        stats.observationBlock = stamp
        stats.observedAt       = now
        stats.accepted = anchorFor.keys.sorted().compactMap { i in
            guard let key = anchorFor[i], let anchor = brain.object(withKey: key) else { return nil }
            return AcceptedAnchor(anchorKey: key, kind: anchor.kind, label: anchor.label,
                                  labelSource: anchor.labelSource, detectedLabel: interactive[i].label,
                                  isNew: createdKeys.contains(key))
        }
        return stats
    }

    /// Updates a matched anchor: counts, recency, bounds, state, and the label ledger. A model-assigned
    /// name is immutable to observation; variants collect as aliases.
    private static func refresh(_ anchor: inout ObjectAnchor, with detection: BrainDetection, now: Date,
                                stamp: Int, window: String?) {
        anchor.seenCount     += 1
        anchor.lastSeen      = now
        anchor.lastSeenEpoch = stamp
        anchor.window        = window ?? anchor.window
        anchor.boundsTypical = detection.bounds
        if let state = detection.state { anchor.statesSeen[state.rawValue, default: 0] += 1 }
        let normalized = LabelText.normalize(detection.label)
        guard !normalized.isEmpty else { return }
        if anchor.label.isEmpty, anchor.labelSource != .llm {
            anchor.label       = detection.label
            anchor.labelSource = .observed
        } else if LabelText.normalize(anchor.label) != normalized,
                  !anchor.aliases.contains(where: { LabelText.normalize($0) == normalized }) {
            anchor.aliases.append(detection.label)
        }
    }

    /// Persists a detected group across scenes. A merge is gated on member overlap, cell size and axis
    /// position (measured failure: a sidebar's rows unioned into a switch column); after every merge,
    /// members that no longer align are evicted.
    private static func mergeGroup(
        _ candidate: SiblingGroupDetector.GroupCandidate,
        members    : [String],
        interactive: [BrainDetection],
        into brain : inout UIBrain,
        now        : Date,
        epoch      : Int
    ) {
        let axisPositions = candidate.memberIndices.map {
            candidate.axis == .column ? interactive[$0].bounds.x : interactive[$0].bounds.y
        }
        let candidateMedian = median(axisPositions)
        let existing = brain.groups.firstIndex { group in
            guard group.axis == candidate.axis, group.sharedKind == candidate.sharedKind,
                  Double(Set(group.memberAnchors).intersection(members).count)
                      >= 0.5 * Double(min(group.memberAnchors.count, members.count)),
                  cellsSimilar(group.cellSize, candidate.cellSize) else { return false }
            let cell = candidate.cellSize.extent(along: candidate.axis)
            return abs(axisPosition(of: group, in: brain) - candidateMedian) <= max(2 * cell, 0.03)
        }
        if let gi = existing {
            let union = Set(brain.groups[gi].memberAnchors).union(members)
            brain.groups[gi].memberAnchors = ordered(anchors: union, in: brain, axis: candidate.axis)
            brain.groups[gi].cellSize      = candidate.cellSize
            brain.groups[gi].seenCount     += 1
            brain.groups[gi].lastSeen      = now
            brain.groups[gi].lastSeenEpoch = epoch
            if brain.groups[gi].name == nil { brain.groups[gi].name = candidate.name }
            evictMisaligned(groupIndex: gi, in: &brain)
            assignGroupID(brain.groups[gi].id, to: brain.groups[gi].memberAnchors, in: &brain)
        } else {
            let group = SiblingGroup(axis: candidate.axis, memberAnchors: members, sharedKind: candidate.sharedKind,
                                     cellSize: candidate.cellSize, name: candidate.name, lastSeen: now,
                                     lastSeenEpoch: epoch)
            assignGroupID(group.id, to: members, in: &brain)
            brain.groups.append(group)
        }
    }

    // MARK: Decay

    /// Forgets by evidence of absence: the application was observed more times and this was not there.
    /// A seen-once object unseen for the transient span, or anything unseen for the stale span or the
    /// wall-clock backstop, is dropped. A protected object is never dropped and sits outside the cap;
    /// the cap keeps the most established unprotected rows. Groups lose dropped members and dissolve
    /// under three members or when stale. Evidence-one transitions die as coincidences, except menu
    /// reveals; every transition dies when stale. Rows never stamped count as seen now.
    public static func decay(
        _ brain    : inout UIBrain,
        now        : Date,
        maxObjects : Int = 3000,
        retention  : BrainRetention = .standard
    ) {
        let epoch = brain.ingestEpoch
        let backstop = now.addingTimeInterval(-retention.backstopDays * 86400)
        let snapshot = brain
        var objects = brain.objects.filter { anchor in
            if anchor.isProtected { return true }
            let unseen = snapshot.unseenFor(window: anchor.window, stamp: anchor.lastSeenEpoch)
            if anchor.lastSeen < backstop { return false }
            if unseen >= retention.staleIngests { return false }
            if anchor.seenCount <= 1 && unseen >= retention.transientIngests { return false }
            return true
        }
        let protected = objects.filter(\.isProtected)
        var unprotected = objects.filter { !$0.isProtected }
        if unprotected.count > maxObjects {
            unprotected = Array(unprotected.sorted { lhs, rhs in
                lhs.seenCount != rhs.seenCount ? lhs.seenCount > rhs.seenCount : lhs.lastSeen > rhs.lastSeen
            }.prefix(maxObjects))
            let keptKeys = Set(protected.map(\.anchorKey) + unprotected.map(\.anchorKey))
            objects = objects.filter { keptKeys.contains($0.anchorKey) }
        }
        let kept = Set(objects.map(\.anchorKey))
        brain.objects = objects
        brain.groups = brain.groups.compactMap { group in
            var group = group
            group.memberAnchors = group.memberAnchors.filter { kept.contains($0) }
            let unseen = max(0, epoch - (group.lastSeenEpoch ?? epoch))
            guard group.memberAnchors.count >= 3, unseen < retention.staleIngests, group.lastSeen >= backstop else {
                for key in group.memberAnchors {
                    if let i = brain.objectIndex(withKey: key) { brain.objects[i].groupID = nil }
                }
                return nil
            }
            return group
        }
        brain.transitions = brain.transitions.filter { transition in
            guard kept.contains(transition.anchorKey), transition.lastObserved >= backstop else { return false }
            let unseen = max(0, epoch - (transition.lastObservedEpoch ?? epoch))
            if unseen >= retention.transitionStaleIngests { return false }
            let coincidence = transition.evidence <= 1 && !transition.isMenuReveal
            return !(coincidence && unseen >= retention.coincidenceIngests)
        }
    }

    // MARK: Deliberate knowledge

    /// Names an anchor deliberately (source `llm`). The old observed label survives as an alias so
    /// perception can still match it. Returns false when the anchor does not exist.
    @discardableResult
    public static func setName(_ name: String, anchorKey: String, into brain: inout UIBrain, now: Date) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = brain.objectIndex(withKey: anchorKey) else { return false }
        let old = brain.objects[i].label
        if !old.isEmpty, LabelText.normalize(old) != LabelText.normalize(trimmed),
           !brain.objects[i].aliases.contains(where: { LabelText.normalize($0) == LabelText.normalize(old) }) {
            brain.objects[i].aliases.append(old)
        }
        brain.objects[i].label         = trimmed
        brain.objects[i].labelSource   = .llm
        brain.objects[i].lastSeen      = now
        brain.objects[i].lastSeenEpoch = brain.stamp(for: brain.objects[i].window)
        return true
    }

    /// Records a learned transition. The same anchor, trigger and effect add evidence; consumers trust a
    /// state effect only at evidence two or more. Returns the evidence after recording.
    public static func recordTransition(
        anchorKey : String,
        trigger   : TransitionTrigger,
        effect    : String,
        into brain: inout UIBrain,
        now       : Date
    ) -> Int {
        if let i = brain.transitions.firstIndex(where: {
            $0.anchorKey == anchorKey && $0.trigger == trigger && $0.effect == effect
        }) {
            brain.transitions[i].evidence          += 1
            brain.transitions[i].lastObserved      = now
            brain.transitions[i].lastObservedEpoch = brain.ingestEpoch
            return brain.transitions[i].evidence
        }
        brain.transitions.append(LearnedTransition(anchorKey: anchorKey, trigger: trigger, effect: effect,
                                                   lastObserved: now, lastObservedEpoch: brain.ingestEpoch))
        return 1
    }

    // MARK: Group geometry

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func cellsSimilar(_ lhs: NormalizedSize, _ rhs: NormalizedSize) -> Bool {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return true }
        return max(lhs.width, rhs.width) / min(lhs.width, rhs.width) <= 1.35
            && max(lhs.height, rhs.height) / min(lhs.height, rhs.height) <= 1.35
    }

    /// A group's position along its alignment axis: the median member x for a column, y for a row.
    static func axisPosition(of group: SiblingGroup, in brain: UIBrain) -> Double {
        median(group.memberAnchors.compactMap { key in
            brain.object(withKey: key).map { group.axis == .column ? $0.boundsTypical.x : $0.boundsTypical.y }
        })
    }

    /// Drops members whose current bounds no longer align with the group's axis: impostors absorbed
    /// before the merge gates existed, or objects that moved away.
    static func evictMisaligned(groupIndex gi: Int, in brain: inout UIBrain) {
        let group = brain.groups[gi]
        let axisPosition = axisPosition(of: group, in: brain)
        let tolerance = max(0.6 * group.cellSize.extent(along: group.axis), 0.012)
        let cellRect = NormalizedRect(x: 0, y: 0, width: group.cellSize.width, height: group.cellSize.height)
        var kept: [String] = [], evicted: [String] = []
        for key in group.memberAnchors {
            guard let anchor = brain.object(withKey: key) else { continue }
            let position = group.axis == .column ? anchor.boundsTypical.x : anchor.boundsTypical.y
            let sizeOK = BrainMatcher.sizeCompatible(anchor.boundsTypical, cellRect)
            if abs(position - axisPosition) <= tolerance && sizeOK { kept.append(key) } else { evicted.append(key) }
        }
        brain.groups[gi].memberAnchors = kept
        for key in evicted {
            if let i = brain.objectIndex(withKey: key) { brain.objects[i].groupID = nil }
        }
    }

    static func assignGroupID(_ id: UUID, to anchors: [String], in brain: inout UIBrain) {
        for key in anchors {
            if let i = brain.objectIndex(withKey: key) { brain.objects[i].groupID = id }
        }
    }

    static func ordered(anchors: Set<String>, in brain: UIBrain, axis: GroupAxis) -> [String] {
        anchors.compactMap(brain.object(withKey:))
            .sorted { lhs, rhs in
                axis == .column ? lhs.boundsTypical.midY < rhs.boundsTypical.midY
                                : lhs.boundsTypical.midX < rhs.boundsTypical.midX
            }
            .map(\.anchorKey)
    }
}

//
//  BrainGraph.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import PerceptionCore

/// ArcTrigger is what triggers a general arc of the brain's graph: an anchor or a scene element with
/// the gesture (`TransitionTrigger`), or a menu command, stored with the trigger code `menu` (this
/// contract's proposal). An anchor triggered arc from the application's scope is the projection's,
/// `LearnedTransition`, and is not a general arc.
public enum ArcTrigger: Sendable {
    case anchor(anchorID: String, gesture: TransitionTrigger)
    case element(sceneElementID: String, gesture: TransitionTrigger)
    case menu(menuCommandID: String)

    public static let menuCode = "menu"
}

/// ArcStatus is a general arc's standing as its writer states it: no threshold or formula promotes
/// it here, unlike the projection's derived trust.
public enum ArcStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case candidate, trusted, rejected
}

/// BrainArc is one general arc, defined explicitly, not learned: from a scene (structural or the
/// application's scope), by a trigger, to a structural scene or to an unknown destination (nil),
/// with its effect in typed columns and rows. What names the arc never changes (id, application,
/// source, trigger, destination, effect, first sighting); its status, its count of supporting
/// observations as stated by its writer, its last sighting and epoch change through an update
/// against the arc last read. Compared with `isExactly(_:)`.
public struct BrainArc: Sendable {
    public let transitionID: String
    public let bundleID: String
    public let fromSceneID: String
    public let trigger: ArcTrigger
    public let toSceneID: String?
    public let effect: TransitionEffectRecord
    public let status: ArcStatus
    public let evidenceCount: Int64
    public let firstSeenMS: Int64
    public let lastSeenMS: Int64
    public let lastObservedEpoch: Int64?

    public init(transitionID: String, bundleID: String, fromSceneID: String, trigger: ArcTrigger, toSceneID: String? = nil,
                effect: TransitionEffectRecord, status: ArcStatus, evidenceCount: Int64, firstSeenMS: Int64, lastSeenMS: Int64,
                lastObservedEpoch: Int64? = nil) throws {
        func refuse(_ invalidity: EventFactError.Invalidity) -> EventFactError { .invalidRecord(invalidity) }
        if transitionID.isEmpty || bundleID.isEmpty || fromSceneID.isEmpty { throw refuse(.emptyID) }
        switch trigger {
            case .anchor(let id, _), .element(let id, _), .menu(let id): if id.isEmpty { throw refuse(.emptyID) }
        }
        if let toSceneID, toSceneID.isEmpty { throw refuse(.emptyID) }
        if evidenceCount < 0 { throw refuse(.outOfRange(field: "evidence_count")) }
        if let lastObservedEpoch, lastObservedEpoch < 0 { throw refuse(.outOfRange(field: "last_observed_epoch")) }
        for instant in [firstSeenMS, lastSeenMS] where !BrainClock.range.contains(instant) { throw refuse(.outOfRange(field: "ms")) }
        if lastSeenMS < firstSeenMS { throw refuse(.outOfOrder(field: "last_seen_ms")) }
        self.transitionID      = transitionID
        self.bundleID          = bundleID
        self.fromSceneID       = fromSceneID
        self.trigger           = trigger
        self.toSceneID         = toSceneID
        self.effect            = effect
        self.status            = status
        self.evidenceCount     = evidenceCount
        self.firstSeenMS       = firstSeenMS
        self.lastSeenMS        = lastSeenMS
        self.lastObservedEpoch = lastObservedEpoch
    }

    /// Whether the other arc names the same arc: what an update keeps.
    public func sameIdentity(as other: BrainArc) -> Bool {
        let triggers: Bool
        switch (trigger, other.trigger) {
            case (.anchor(let a, let g), .anchor(let b, let h)), (.element(let a, let g), .element(let b, let h)): triggers = a.utf8.elementsEqual(b.utf8) && g == h
            case (.menu(let a), .menu(let b)): triggers = a.utf8.elementsEqual(b.utf8)
            default: triggers = false
        }
        return triggers && transitionID.utf8.elementsEqual(other.transitionID.utf8) && bundleID.utf8.elementsEqual(other.bundleID.utf8)
            && fromSceneID.utf8.elementsEqual(other.fromSceneID.utf8) && EventFactText.same(toSceneID, other.toSceneID)
            && effect.kind.utf8.elementsEqual(other.effect.kind.utf8) && EventFactText.same(effect.text, other.effect.text)
            && effect.requiredState == other.effect.requiredState && effect.resultingState == other.effect.resultingState
            && effect.items.count == other.effect.items.count && zip(effect.items, other.effect.items).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
            && firstSeenMS == other.firstSeenMS
    }

    public func isExactly(_ other: BrainArc) -> Bool {
        sameIdentity(as: other) && status == other.status && evidenceCount == other.evidenceCount && lastSeenMS == other.lastSeenMS
            && lastObservedEpoch == other.lastObservedEpoch
    }
}

/// SceneElementScope is a scene element's place in its structure, the schema's vocabulary.
public enum SceneElementScope: String, Sendable, Equatable, Hashable, CaseIterable {
    case container, control, collection
    case itemTemplate = "item_template"
}

/// SceneElementRecord is one element of a structural scene as the store keeps it, every column
/// typed: its key in the scene, its scope and parent, the anchor it is linked to when one is,
/// its label with the attribute it came from, role, kind, the hash and the cursor a producer may
/// state, its bounds whole or absent, and its sightings.
public struct SceneElementRecord: Sendable {
    public let sceneElementID: String
    public let sceneID: String
    public let elementKey: String
    public let scope: SceneElementScope
    public let parentElementID: String?
    public let edgeHash: String?
    public let cursorAffordance: String?
    public let anchorID: String?
    public let label: String?
    public let labelOrigin: LabelOrigin?
    public let role: String?
    public let kind: String?
    public let source: String?
    public let bounds: NormalizedRect?
    public let firstSeenMS: Int64
    public let lastSeenMS: Int64
    public let observationCount: Int64

    public init(sceneElementID: String, sceneID: String, elementKey: String, scope: SceneElementScope, parentElementID: String?,
                edgeHash: String?, cursorAffordance: String?, anchorID: String?, label: String?, labelOrigin: LabelOrigin?, role: String?,
                kind: String?, source: String?, bounds: NormalizedRect?, firstSeenMS: Int64, lastSeenMS: Int64, observationCount: Int64) {
        self.sceneElementID   = sceneElementID
        self.sceneID          = sceneID
        self.elementKey       = elementKey
        self.scope            = scope
        self.parentElementID  = parentElementID
        self.edgeHash         = edgeHash
        self.cursorAffordance = cursorAffordance
        self.anchorID         = anchorID
        self.label            = label
        self.labelOrigin      = labelOrigin
        self.role             = role
        self.kind             = kind
        self.source           = source
        self.bounds           = bounds
        self.firstSeenMS      = firstSeenMS
        self.lastSeenMS       = lastSeenMS
        self.observationCount = observationCount
    }
}

/// BrainEvidenceTarget is the one thing a brain evidence row is about: a scene, an anchor, a scene
/// element, a group, a menu command or a transition. Never the application's scope itself.
public enum BrainEvidenceTarget: Sendable {
    case scene(String)
    case anchor(String)
    case sceneElement(String)
    case group(String)
    case menuCommand(String)
    case transition(String)

    var id: String {
        switch self {
            case .scene(let id), .anchor(let id), .sceneElement(let id), .group(let id), .menuCommand(let id), .transition(let id): id
        }
    }
}

/// BrainEvidenceRecord links an event of an application to what it supports or contradicts in the
/// brain, with who assessed it, under which version and when. A link is not independence and moves
/// no count: counters are never recomputed from links. Compared with `isExactly(_:)`.
public struct BrainEvidenceRecord: Sendable {
    public let bundleID: String
    public let eventID: String
    public let target: BrainEvidenceTarget
    public let relation: EvidenceRelation
    public let assessedBy: String
    public let assessmentVersion: String
    public let assessedAtMS: Int64

    public init(bundleID: String, eventID: String, target: BrainEvidenceTarget, relation: EvidenceRelation, assessedBy: String,
                assessmentVersion: String, assessedAtMS: Int64) throws {
        func refuse(_ invalidity: EventFactError.Invalidity) -> EventFactError { .invalidRecord(invalidity) }
        if bundleID.isEmpty || eventID.isEmpty || target.id.isEmpty { throw refuse(.emptyID) }
        if assessedBy.isEmpty { throw refuse(.emptyText(field: "assessed_by")) }
        if assessmentVersion.isEmpty { throw refuse(.emptyText(field: "assessment_version")) }
        if !BrainClock.range.contains(assessedAtMS) { throw refuse(.outOfRange(field: "ms")) }
        self.bundleID          = bundleID
        self.eventID           = eventID
        self.target            = target
        self.relation          = relation
        self.assessedBy        = assessedBy
        self.assessmentVersion = assessmentVersion
        self.assessedAtMS      = assessedAtMS
    }

    public func isExactly(_ other: BrainEvidenceRecord) -> Bool {
        let targets: Bool
        switch (target, other.target) {
            case (.scene(let a), .scene(let b)), (.anchor(let a), .anchor(let b)), (.sceneElement(let a), .sceneElement(let b)),
                 (.group(let a), .group(let b)), (.menuCommand(let a), .menuCommand(let b)), (.transition(let a), .transition(let b)):
                targets = a.utf8.elementsEqual(b.utf8)
            default:
                targets = false
        }
        return targets && bundleID.utf8.elementsEqual(other.bundleID.utf8) && eventID.utf8.elementsEqual(other.eventID.utf8)
            && relation == other.relation && assessedBy.utf8.elementsEqual(other.assessedBy.utf8)
            && assessmentVersion.utf8.elementsEqual(other.assessmentVersion.utf8) && assessedAtMS == other.assessedAtMS
    }
}

/// MemoryOverview is what the store holds, per application and overall, read without an open
/// application and without rebuilding any `AppKnowledge`: the compatible projection, the scenes and
/// the general graph, the observed facts, and the procedures and experiences.
public struct MemoryOverview: Sendable, Equatable {

    public struct App: Sendable, Equatable {
        public let bundleID: String
        public let contexts: Int
        public let projectionAnchors: Int
        public let projectionGroups: Int
        public let projectionTransitions: Int
        public let structuralScenes: Int
        public let sceneElements: Int
        public let generalArcs: Int
        public let menuCommands: Int
        public let brainEvidence: Int
        public let events: Int
        public let samples: Int

        public init(bundleID: String, contexts: Int, projectionAnchors: Int, projectionGroups: Int, projectionTransitions: Int,
                    structuralScenes: Int, sceneElements: Int, generalArcs: Int, menuCommands: Int, brainEvidence: Int, events: Int, samples: Int) {
            self.bundleID              = bundleID
            self.contexts              = contexts
            self.projectionAnchors     = projectionAnchors
            self.projectionGroups      = projectionGroups
            self.projectionTransitions = projectionTransitions
            self.structuralScenes      = structuralScenes
            self.sceneElements         = sceneElements
            self.generalArcs           = generalArcs
            self.menuCommands          = menuCommands
            self.brainEvidence         = brainEvidence
            self.events                = events
            self.samples               = samples
        }
    }

    public let apps: [App]
    public let routes: [RouteStatus: Int]
    public let experiences: Int
    public let taskOccurrences: Int
    public let stepOccurrences: Int
    public let eventsWithoutApp: Int

    public init(apps: [App], routes: [RouteStatus: Int], experiences: Int, taskOccurrences: Int, stepOccurrences: Int, eventsWithoutApp: Int) {
        self.apps             = apps
        self.routes           = routes
        self.experiences      = experiences
        self.taskOccurrences  = taskOccurrences
        self.stepOccurrences  = stepOccurrences
        self.eventsWithoutApp = eventsWithoutApp
    }
}

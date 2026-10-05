//
//  SceneDefinition.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore

/// SceneDefinition is one structural scene as the living memory holds it: its identity, the
/// application it belongs to, the surface it is (`scene_kind`, never a pop-up union and never
/// unknown), the title bucket kept as a search hint, the structural key kept as another, the span
/// of its observations and their count, and the skeleton rebuilt from its stored elements. The app
/// scope (`scene_kind = 'app'`) is not a scene definition: it is never read as one and never
/// offered as a candidate.
public struct SceneDefinition: Sendable, Equatable {

    public let id: String
    public let bundleID: String
    public let surface: CaptureSurface
    public let titleBucket: String
    public let structuralKey: String?
    public let firstSeenMS: Int64
    public let lastSeenMS: Int64
    public let observationCount: Int
    public let skeleton: SceneSkeleton

    public init(
        id              : String,
        bundleID        : String,
        surface         : CaptureSurface,
        titleBucket     : String,
        structuralKey   : String?,
        firstSeenMS     : Int64,
        lastSeenMS      : Int64,
        observationCount: Int,
        skeleton        : SceneSkeleton
    ) {
        self.id               = id
        self.bundleID         = bundleID
        self.surface          = surface
        self.titleBucket      = titleBucket
        self.structuralKey    = structuralKey
        self.firstSeenMS      = firstSeenMS
        self.lastSeenMS       = lastSeenMS
        self.observationCount = observationCount
        self.skeleton         = skeleton
    }
}

/// SceneMatchStatus is what an association says about a sample and a scene.
public enum SceneMatchStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case candidate, confirmed, rejected
}

/// SceneAssociation is one row of the relation between a sample and a scene: the decision's status,
/// and the method and version that made it, so a later matcher can tell its own decisions from an
/// earlier one's. Confidence is not carried: structure-v3 has no score.
public struct SceneAssociation: Sendable, Equatable, Hashable {

    public let sample: CaptureSampleKey
    public let sceneID: String
    public let status: SceneMatchStatus
    public let matchedBy: String
    public let matcherVersion: String

    public init(
        sample        : CaptureSampleKey,
        sceneID       : String,
        status        : SceneMatchStatus,
        matchedBy     : String,
        matcherVersion: String
    ) {
        self.sample         = sample
        self.sceneID        = sceneID
        self.status         = status
        self.matchedBy      = matchedBy
        self.matcherVersion = matcherVersion
    }
}

/// SceneAssociationOutcome is what associating a sample produced: `committed` when this call
/// evaluated the sample and wrote what its decision required (possibly no row), `alreadyApplied`
/// when a decision for this sample was already stored and is what `associations` returns; the
/// decision; the association rows now stored for the sample; and the scene this call created, if any.
public struct SceneAssociationOutcome: Sendable, Equatable {

    public let receipt: MemoryReceipt
    public let decision: SceneStructureMatcher.Decision
    public let associations: [SceneAssociation]
    public let createdSceneID: String?

    public init(
        receipt       : MemoryReceipt,
        decision      : SceneStructureMatcher.Decision,
        associations  : [SceneAssociation],
        createdSceneID: String?
    ) {
        self.receipt        = receipt
        self.decision       = decision
        self.associations   = associations
        self.createdSceneID = createdSceneID
    }
}

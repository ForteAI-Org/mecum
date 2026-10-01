//
//  Sighting.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation

/// SightingObservation is one accepted match of one scene, projected for the living memory: which
/// object, under what name and name provenance, when, and in which observation block of the brain.
public struct SightingObservation: Sendable, Equatable, Codable {

    public let key: SightingKey

    /// The name shown or assigned, as displayed.
    public let name: String

    /// Where the name came from; `nil` reads as observed, as it does for an anchor.
    public let nameSource: LabelSource?

    public let seenAt: Date

    /// The brain's observation clock for this window when the scene was ingested. One block is at
    /// most one unit of evidence however many frames it holds.
    public let observationBlock: Int

    public init(key: SightingKey, name: String, nameSource: LabelSource?, seenAt: Date, observationBlock: Int) {
        self.key              = key
        self.name             = name
        self.nameSource       = nameSource
        self.seenAt           = seenAt
        self.observationBlock = observationBlock
    }
}

/// Sighting is the durable record that an object was seen in a window context: "I observed this
/// element here", never "it is here now". Presence for an action always comes from a fresh scene.
///
/// Two counters with different meanings: `readCount` is diagnostic and grows with every accepted
/// observation, refreshes included; `evidenceCount` grows at most once per brain observation block,
/// tracked by `lastCountedBlock`, so a hundred frames of one block are one piece of evidence.
public struct Sighting: Sendable, Equatable, Codable {

    public let key: SightingKey
    public var name: String
    public var nameSource: LabelSource?
    public var firstSeen: Date
    public var lastSeen: Date
    public var readCount: Int
    public var evidenceCount: Int
    public var lastCountedBlock: Int

    public init(
        key             : SightingKey,
        name            : String,
        nameSource      : LabelSource?,
        firstSeen       : Date,
        lastSeen        : Date,
        readCount       : Int,
        evidenceCount   : Int,
        lastCountedBlock: Int
    ) {
        self.key              = key
        self.name             = name
        self.nameSource       = nameSource
        self.firstSeen        = firstSeen
        self.lastSeen         = lastSeen
        self.readCount        = readCount
        self.evidenceCount    = evidenceCount
        self.lastCountedBlock = lastCountedBlock
    }

    /// The first sighting of an object.
    public init(first observation: SightingObservation) {
        self.init(
            key             : observation.key,
            name            : observation.name,
            nameSource      : observation.nameSource,
            firstSeen       : observation.seenAt,
            lastSeen        : observation.seenAt,
            readCount       : 1,
            evidenceCount   : 1,
            lastCountedBlock: observation.observationBlock
        )
    }

    /// Folds a later observation of the same key in. Dates widen, the read count grows, and the
    /// evidence count grows only for a block newer than the last one counted. A name a model or a
    /// person assigned is kept against an observed one, the rule the brain applies to anchors.
    /// An observation of another key changes nothing and answers false.
    @discardableResult
    public mutating func merge(_ observation: SightingObservation) -> Bool {
        guard observation.key == key else { return false }
        firstSeen = min(firstSeen, observation.seenAt)
        lastSeen  = max(lastSeen, observation.seenAt)
        readCount += 1
        if observation.observationBlock > lastCountedBlock {
            evidenceCount   += 1
            lastCountedBlock = observation.observationBlock
        }
        let keepsAssignedName = Self.isAssigned(nameSource) && !Self.isAssigned(observation.nameSource)
        if !keepsAssignedName {
            name       = observation.name
            nameSource = observation.nameSource
        }
        return true
    }

    /// The order every store returns sightings in: bundle, window family, then identity.
    public static func isOrderedBefore(_ lhs: Sighting, _ rhs: Sighting) -> Bool {
        let left  = (lhs.key.context.bundleID, lhs.key.context.windowFamily, lhs.key.identity.storageKey)
        let right = (rhs.key.context.bundleID, rhs.key.context.windowFamily, rhs.key.identity.storageKey)
        return left < right
    }

    private static func isAssigned(_ source: LabelSource?) -> Bool { source == .llm || source == .user }
}

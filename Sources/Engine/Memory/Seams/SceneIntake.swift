//
//  SceneIntake.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import PerceptionCore

/// SceneIntake is the one path a scene that was already captured takes into memory: the brain
/// observes it, the living memory records the sightings its accepted anchors evidence, and the
/// brain enriches it. Opening, observing, and the scenes returned by actions all use it.
///
/// It holds no scene provider, so it can never capture: memory learns only from what the action
/// or observation already saw. A brain failure throws, as observing always has. A living-memory
/// failure never blocks the brain or the caller: it is returned in `SceneLearning.sightings`, and
/// the brain's own write-behind is not waited on, so a sighting's anchor key may briefly name an
/// anchor that is only in memory (see `SightingProjection`).
public struct SceneIntake: Sendable {

    private let brain: BrainMemory
    private let livingMemory: (any LivingMemoryStoring)?

    /// - Parameter livingMemory: the store sightings go to; nil records none, which is not an error.
    public init(brain: BrainMemory, livingMemory: (any LivingMemoryStoring)?) {
        self.brain        = brain
        self.livingMemory = livingMemory
    }

    /// Sightings is what the living memory did with one scene.
    public enum Sightings: Sendable, Equatable {
        /// The records written or merged.
        case recorded([Sighting])
        /// The scene evidences no sighting, and why.
        case abstained(SightingProjection.Abstention)
        /// No living memory was composed.
        case notConfigured
        /// The store refused or failed; nothing about this scene was written to it.
        case failed(String)
    }

    /// SceneLearning is one scene's intake result.
    public struct SceneLearning: Sendable, Equatable {
        /// The scene annotated from the brain, as `BrainMemory.enrich` returns it.
        public let scene: SceneSnapshot
        public let ingest: BrainUpdater.IngestStats
        public let sightings: Sightings
    }

    /// Learns from one captured scene.
    /// - Throws: the brain store's error; the living memory is then not written.
    public func learn(from scene: SceneSnapshot) async throws -> SceneLearning {
        let ingest = try await brain.observe(scene)
        let sightings: Sightings
        switch SightingProjection.project(scene, ingest: ingest) {
            case .abstained(let why):
                sightings = .abstained(why)
            case .observations(let observations):
                if let livingMemory {
                    do {
                        sightings = .recorded(try await livingMemory.recordSightings(observations))
                    } catch {
                        sightings = .failed(String(describing: error))
                    }
                } else {
                    sightings = .notConfigured
                }
        }
        return SceneLearning(scene: await brain.enrich(scene), ingest: ingest, sightings: sightings)
    }

    /// Learns from the scene an action's outcome carried, or does nothing when it carried none: an
    /// absent scene is uncertainty, never evidence that something disappeared.
    public func learn(fromOutcomeScene scene: SceneSnapshot?) async throws -> SceneLearning? {
        guard let scene else { return nil }
        return try await learn(from: scene)
    }
}

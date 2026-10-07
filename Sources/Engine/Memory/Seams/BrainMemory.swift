//
//  BrainMemory.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// BrainMemory fills the engine's expectation seam from the stored brain and carries what a producer
/// teaches it to the brain's applications: it answers what a verb on an element is expected to do
/// from trusted transitions, it enriches scenes from the projection, and it turns an observed scene
/// or a performed action into one `BrainApplicationCommand`, applied once per key by the store
/// (`BrainApplicationStoring`), so a retry of the same fact moves no counter. Where the brain learns
/// is unchanged: a scene observed by `open_session`, `observe` or the `scene` command is ingested;
/// an action with an effect is recorded against its element's anchor; nothing else teaches.
///
/// Reads come from `BrainReading`; a read that fails answers no opinion (no expectation, the scene
/// as it was), since neither seam may fail an action. A write that fails is thrown to the producer,
/// which reports the memory as degraded and goes on. The clock arrives at construction; nothing
/// here reads the wall.
public actor BrainMemory: EffectExpecting {

    private let brains: any BrainReading
    private let applications: any BrainApplicationStoring
    private let clock: @Sendable () -> Date

    public init(
        brains      : any BrainReading,
        applications: any BrainApplicationStoring,
        clock       : @escaping @Sendable () -> Date
    ) {
        self.brains       = brains
        self.applications = applications
        self.clock        = clock
    }

    // MARK: EffectExpecting

    /// The strongest trusted transition of the element's anchor under the verb's trigger, decoded, or
    /// nil when the brain has no opinion or the store cannot be read.
    public func expectedEffect(
        of verb    : ActionVerb,
        on element : SceneElement,
        in bundleID: String
    ) async -> SceneEffect? {
        guard let brain = try? await brains.brain(of: bundleID) else { return nil }
        guard case .found(let key) = BrainMatcher.match(BrainDetection(element), in: brain) else { return nil }
        let trigger = TransitionTrigger(verb)
        return brain.transitions
            .filter { $0.anchorKey == key && $0.trigger == trigger && $0.isTrusted }
            .max { $0.evidence < $1.evidence }?
            .sceneEffect
    }

    // MARK: What a producer teaches

    /// Records what an action taught, keyed by the event of the call that performed it: the record's
    /// effect against its element's anchor, with the rules the brain always had (no effect teaches
    /// nothing; an element with no anchor teaches nothing unless it revealed a menu). Nil when the
    /// record carries no effect or no element, which is no application at all. `requestedAt` is the
    /// instant the application is asked for, part of what the store compares a retry against: a
    /// producer passes the call's own instant (its event's), so the same call is the same command;
    /// nil reads the clock.
    public func record(_ record: ActionRecord, eventID: String, requestedAt: Date? = nil) async throws -> BrainApplicationResult? {
        guard record.effect != nil else { return nil }
        let command = try BrainApplicationCommand.record(record, eventID: eventID, requestedAt: requestedAt ?? clock())
        return try await applications.apply(command)
    }

    /// Ingests a scene's elements into its application's brain, scoped to the window's title
    /// family, keyed by the real sample the scene was captured as. `requestedAt` as in `record`.
    @discardableResult
    public func observe(_ scene: SceneSnapshot, sample: CaptureSampleKey, requestedAt: Date? = nil) async throws -> BrainApplicationResult {
        let command = try BrainApplicationCommand.observe(scene, sample: sample, requestedAt: requestedAt ?? clock())
        return try await applications.apply(command)
    }

    // MARK: Scenes

    /// The scene with its elements annotated from the brain; the scene itself when the store has
    /// none, or cannot be read.
    public func enrich(_ scene: SceneSnapshot) async -> SceneSnapshot {
        guard let brain = try? await brains.brain(of: scene.bundleID) else { return scene }
        let elements = brain.enrich(scene.elements)
        guard elements != scene.elements else { return scene }
        return SceneSnapshot(
            bundleID         : scene.bundleID,
            appName          : scene.appName,
            windowTitle      : scene.windowTitle,
            viewportPixelSize: scene.viewportPixelSize,
            elements         : elements,
            sections         : scene.sections,
            commands         : scene.commands
        )
    }
}

//
//  BrainMemory.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// BrainMemory fills the engine's two memory seams from the brain behind a `KnowledgeStoring`: it
/// answers what a verb on an element is expected to do from trusted transitions, and it records what
/// each performed action taught. It also observes scenes into the brain and enriches them from it.
/// The clock arrives at construction; nothing here reads the wall.
public actor BrainMemory: EffectExpecting, ActionObserving {

    private let store: any KnowledgeStoring
    private let clock: @Sendable () -> Date

    public init(store: any KnowledgeStoring, clock: @escaping @Sendable () -> Date) {
        self.store = store
        self.clock = clock
    }

    // MARK: EffectExpecting

    /// The strongest trusted transition of the element's anchor under the verb's trigger, decoded, or
    /// nil when the brain has no opinion or the store cannot be read.
    public func expectedEffect(
        of verb    : ActionVerb,
        on element : SceneElement,
        in bundleID: String
    ) async -> SceneEffect? {
        guard let knowledge = try? await store.load(bundleID: bundleID) else { return nil }
        let brain = knowledge.brain
        guard case .found(let key) = BrainMatcher.match(BrainDetection(element), in: brain) else { return nil }
        let trigger = TransitionTrigger(verb)
        return brain.transitions
            .filter { $0.anchorKey == key && $0.trigger == trigger && $0.isTrusted }
            .max { $0.evidence < $1.evidence }?
            .sceneEffect
    }

    // MARK: ActionObserving

    /// Records the effect against the element's anchor. An element with no anchor yet that revealed a
    /// menu is anchored first, because a session once learned nothing from a right-click that opened
    /// a context menu and re-guessed menu titles blind the next time. The role forbids failing the
    /// action, so a store error drops the record.
    public func record(_ record: ActionRecord) async {
        guard let effect = record.effect else { return }
        let now = clock()
        let detection = BrainDetection(record.element)
        let trigger = TransitionTrigger(record.verb)
        do {
            try await store.mutate(bundleID: record.bundleID) { knowledge in
                var key: String?
                if case .found(let found) = BrainMatcher.match(detection, in: knowledge.brain) { key = found }
                if key == nil, case .menuOpened = effect {
                    _ = BrainUpdater.ingest([detection], into: &knowledge.brain, now: now)
                    if case .found(let found) = BrainMatcher.match(detection, in: knowledge.brain) { key = found }
                }
                guard let key else { return }
                _ = BrainUpdater.recordTransition(anchorKey: key, trigger: trigger, effect: effect.encoded,
                                                  into: &knowledge.brain, now: now)
            }
        } catch {
            return
        }
    }

    // MARK: Scenes

    /// Ingests a scene's elements into its application's brain, scoped to the window's title family.
    @discardableResult
    public func observe(_ scene: SceneSnapshot) async throws -> BrainUpdater.IngestStats {
        let now = clock()
        let detections = scene.elements.map(BrainDetection.init)
        let window = LabelText.letters(scene.windowTitle)
        return try await store.mutate(bundleID: scene.bundleID) { knowledge in
            BrainUpdater.ingest(detections, into: &knowledge.brain, now: now, window: window.isEmpty ? nil : window)
        }
    }

    /// The scene with its elements annotated from the brain; the scene itself when the store has none.
    public func enrich(_ scene: SceneSnapshot) async -> SceneSnapshot {
        guard let knowledge = try? await store.load(bundleID: scene.bundleID) else { return scene }
        let elements = knowledge.brain.enrich(scene.elements)
        guard elements != scene.elements else { return scene }
        var enriched = SceneSnapshot(
            bundleID         : scene.bundleID,
            appName          : scene.appName,
            windowTitle      : scene.windowTitle,
            viewportPixelSize: scene.viewportPixelSize,
            elements         : elements,
            sections         : scene.sections,
            commands         : scene.commands
        )
        enriched.coverage = scene.coverage
        return enriched
    }
}

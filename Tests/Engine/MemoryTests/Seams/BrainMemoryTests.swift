//
//  BrainMemoryTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// InMemoryBrainStore is a pure double of the stored brain for the seam's tests: one `UIBrain` per
/// application and each application applied once per key, by the rules the SQLite repositories
/// apply (`BrainUpdater` unchanged, a retry answers the stored outcome). Nothing here is the store.
actor InMemoryBrainStore: BrainReading, BrainApplicationStoring {

    private var brains: [String: UIBrain] = [:]
    private var applied: [BrainApplicationKey: BrainApplicationResult] = [:]
    private var nextID: Int64 = 1

    func brain(of bundleID: String) async throws -> UIBrain? { brains[bundleID] }

    func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        if let stored = applied[command.key] {
            return BrainApplicationResult(receipt: .alreadyApplied, applicationID: stored.applicationID,
                                          outcome: stored.outcome, requestedAtMS: stored.requestedAtMS,
                                          effectiveAtMS: stored.effectiveAtMS)
        }
        var brain = brains[command.bundleID] ?? UIBrain()
        let now = Date(timeIntervalSince1970: Double(command.requestedAtMS) / 1000)
        let outcome: BrainApplicationOutcome
        switch command.input {
            case .observe(let window, let detections):
                let stats = BrainUpdater.ingest(detections, into: &brain, now: now, window: window)
                outcome = .observed(created: stats.created, updated: stats.updated, skippedAmbiguous: stats.skippedAmbiguous)
            case .record(let verb, let target, let effect):
                guard let effect else { outcome = .noEffect; break }
                var key: String?
                if case .found(let found) = BrainMatcher.match(target, in: brain) { key = found }
                if key == nil, effect.kind == "menuOpened" {
                    _ = BrainUpdater.ingest([target], into: &brain, now: now)
                    if case .found(let found) = BrainMatcher.match(target, in: brain) { key = found }
                }
                guard let key else { outcome = .noAnchor; break }
                let evidence = BrainUpdater.recordTransition(
                    anchorKey: key, trigger: TransitionTrigger(verb), effect: effect.effect, into: &brain, now: now
                )
                outcome = .recorded(anchorKey: key, transitionID: "\(key)/\(effect.effect)", evidence: evidence)
            case .setName(let anchorKey, let name):
                outcome = BrainUpdater.setName(name, anchorKey: anchorKey, into: &brain, now: now)
                    ? .named(anchorKey: anchorKey) : .notNamed
        }
        brains[command.bundleID] = brain
        let result = BrainApplicationResult(receipt: .committed, applicationID: nextID, outcome: outcome,
                                            requestedAtMS: command.requestedAtMS, effectiveAtMS: command.requestedAtMS)
        nextID += 1
        applied[command.key] = result
        return result
    }

    func application(_ key: BrainApplicationKey) async throws -> BrainApplication? { nil }
}

@Suite("The brain seam: expectations in, records out")
struct BrainMemoryTests {

    private let bundle = "com.adobe.PremierePro"
    private let export = SceneElement(id: "control|export", kind: .control, label: "Export", bounds: Fixtures.rect(0.1, 0.1, 0.05, 0.02))
    private let platform = SceneElement(id: "control|platform", kind: .control, label: "Platform", bounds: Fixtures.rect(0.5, 0.1, 0.05, 0.02))

    private func scene(_ elements: [SceneElement], title: String = "Export Settings") -> SceneSnapshot {
        SceneSnapshot(bundleID: bundle, appName: "Premiere", windowTitle: title,
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
    }

    private func memory(_ store: InMemoryBrainStore) -> BrainMemory {
        BrainMemory(brains: store, applications: store, clock: { Fixtures.t0 })
    }

    private func sample(_ event: String) -> CaptureSampleKey { CaptureSampleKey(eventID: event, phase: .current) }

    private func record(_ element: SceneElement, _ effect: SceneEffect?) -> ActionRecord {
        ActionRecord(bundleID: bundle, element: element, verb: .click, effect: effect, windowTitleAfter: nil)
    }

    @Test("observing a scene anchors its elements, scoped to the window's title family, once per sample")
    func observe() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        let result = try await memory.observe(scene([export, platform,
            SceneElement(id: "control|cancel", kind: .control, label: "Cancel", bounds: Fixtures.rect(0.3, 0.1, 0.05, 0.02))]),
            sample: sample("e1"))
        #expect(result.outcome == .observed(created: 3, updated: 0, skippedAmbiguous: 0))
        #expect(result.receipt == .committed)
        let brain = try #require(await store.brain(of: bundle))
        #expect(brain.objects.count == 3)
        #expect(brain.objects.allSatisfy { $0.window == "exportsettings" })
        #expect(brain.ingestEpoch == 1)
        // The same sample offered again is the same observation: the brain's clock does not move.
        let again = try await memory.observe(scene([export, platform]), sample: sample("e1"))
        #expect(again.receipt == .alreadyApplied)
        #expect(try #require(await store.brain(of: bundle)).ingestEpoch == 1)
    }

    @Test("an expectation comes only from a trusted transition of the element's anchor, counted per call")
    func expectation() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        _ = try await memory.observe(scene([export, platform]), sample: sample("e1"))
        let taught = record(export, .elementsAppeared(labels: ["Queue", "Export"]))
        let first = try #require(try await memory.record(taught, eventID: "r1"))
        #expect(first.outcome == .recorded(anchorKey: try #require(await store.brain(of: bundle)).objects[0].anchorKey,
                                           transitionID: first.outcome.transitionID ?? "", evidence: 1))
        #expect(await memory.expectedEffect(of: .click, on: export, in: bundle) == nil, "one observation is not causality")
        // The same call offered again is a retry of one fact, not a second observation.
        let retry = try #require(try await memory.record(taught, eventID: "r1"))
        #expect(retry.receipt == .alreadyApplied)
        #expect(await memory.expectedEffect(of: .click, on: export, in: bundle) == nil)
        _ = try await memory.record(taught, eventID: "r2")
        #expect(await memory.expectedEffect(of: .click, on: export, in: bundle) == .elementsAppeared(labels: ["Queue", "Export"]))
        #expect(await memory.expectedEffect(of: .rightClick, on: export, in: bundle) == nil, "another trigger, no opinion")
        #expect(await memory.expectedEffect(of: .click, on: platform, in: bundle) == nil)
    }

    @Test("a menu reveal is trusted at once and anchors an element the brain had never seen")
    func menuReveal() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        _ = try await memory.record(record(platform, .menuOpened(labels: ["Desktop", "Mobile", "Web"])), eventID: "r1")
        let brain = try #require(await store.brain(of: bundle))
        #expect(brain.objects.count == 1)
        #expect(brain.transitions.count == 1)
        #expect(await memory.expectedEffect(of: .click, on: platform, in: bundle) == .menuOpened(labels: ["Desktop", "Mobile", "Web"]))
        #expect(brain.revealers(of: "Mobile").first?.label == "Platform")
    }

    @Test("a record without an effect or an element is no application; an unknown element with a non-menu effect teaches nothing")
    func nothingLearned() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        #expect(try await memory.record(record(export, nil), eventID: "r1") == nil)
        #expect(try await memory.record(
            ActionRecord(bundleID: bundle, element: nil, verb: .click, effect: .stateFlip(from: .off, to: .on),
                         windowTitleAfter: nil, attempt: .notAttempted(reason: "honest_miss")),
            eventID: "r2") == nil)
        let unknown = try #require(try await memory.record(record(export, .stateFlip(from: .off, to: .on)), eventID: "r3"))
        #expect(unknown.outcome == .noAnchor)
        #expect(try await store.brain(of: bundle)?.transitions.isEmpty ?? true)
    }

    @Test("enrich annotates a scene from the brain and returns the same scene when it has nothing to add")
    func enrich() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        let untouched = scene([export])
        #expect(await memory.enrich(untouched) == untouched)
        _ = try await memory.observe(untouched, sample: sample("e1"))
        _ = try await memory.record(record(export, .menuOpened(labels: ["Queue"])), eventID: "r1")
        let enriched = await memory.enrich(untouched)
        #expect(enriched.elements[0].does == "click: opens menu(Queue)")
        #expect(enriched.elements[0].bounds == export.bounds)
        #expect(enriched.token == untouched.token, "an annotation never moves the token an action must echo")
    }
}

private extension BrainApplicationOutcome {
    var transitionID: String? {
        if case .recorded(_, let id, _) = self { id } else { nil }
    }
}

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

@Suite("The brain seam: expectations in, records out")
struct BrainMemoryTests {

    private let bundle = "com.adobe.PremierePro"
    private let export = SceneElement(id: "control|export", kind: .control, label: "Export", bounds: Fixtures.rect(0.1, 0.1, 0.05, 0.02))
    private let platform = SceneElement(id: "control|platform", kind: .control, label: "Platform", bounds: Fixtures.rect(0.5, 0.1, 0.05, 0.02))

    private func scene(_ elements: [SceneElement], title: String = "Export Settings") -> SceneSnapshot {
        SceneSnapshot(bundleID: bundle, appName: "Premiere", windowTitle: title,
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
    }

    private func memory(_ store: InMemoryKnowledgeStore) -> BrainMemory {
        BrainMemory(store: store, clock: { Fixtures.t0 })
    }

    @Test("observing a scene anchors its elements, scoped to the window's title family")
    func observe() async throws {
        let store = InMemoryKnowledgeStore()
        let stats = try await memory(store).observe(scene([export, platform,
            SceneElement(id: "control|cancel", kind: .control, label: "Cancel", bounds: Fixtures.rect(0.3, 0.1, 0.05, 0.02))]))
        #expect(stats.created == 3)
        let brain = try #require(await store.load(bundleID: bundle)).brain
        #expect(brain.objects.count == 3)
        #expect(brain.objects.allSatisfy { $0.window == "exportsettings" })
        #expect(brain.ingestEpoch == 1)
    }

    @Test("an expectation comes only from a trusted transition of the element's anchor")
    func expectation() async throws {
        let store = InMemoryKnowledgeStore()
        let memory = memory(store)
        try await memory.observe(scene([export, platform]))
        let record = ActionRecord(bundleID: bundle, element: export, verb: .click,
                                  effect: .elementsAppeared(labels: ["Queue", "Export"]), windowTitleAfter: nil)
        await memory.record(record)
        #expect(await memory.expectedEffect(of: .click, on: export, in: bundle) == nil, "one observation is not causality")
        await memory.record(record)
        #expect(await memory.expectedEffect(of: .click, on: export, in: bundle) == .elementsAppeared(labels: ["Queue", "Export"]))
        #expect(await memory.expectedEffect(of: .rightClick, on: export, in: bundle) == nil, "another trigger, no opinion")
        #expect(await memory.expectedEffect(of: .click, on: platform, in: bundle) == nil)
    }

    @Test("a menu reveal is trusted at once and anchors an element the brain had never seen")
    func menuReveal() async throws {
        let store = InMemoryKnowledgeStore()
        let memory = memory(store)
        await memory.record(ActionRecord(bundleID: bundle, element: platform, verb: .click,
                                         effect: .menuOpened(labels: ["Desktop", "Mobile", "Web"]), windowTitleAfter: nil))
        let brain = try #require(await store.load(bundleID: bundle)).brain
        #expect(brain.objects.count == 1)
        #expect(brain.transitions.count == 1)
        #expect(await memory.expectedEffect(of: .click, on: platform, in: bundle) == .menuOpened(labels: ["Desktop", "Mobile", "Web"]))
        #expect(brain.revealers(of: "Mobile").first?.label == "Platform")
    }

    @Test("a record without an effect, or of an unknown element with a non-menu effect, teaches nothing")
    func nothingLearned() async throws {
        let store = InMemoryKnowledgeStore()
        let memory = memory(store)
        await memory.record(ActionRecord(bundleID: bundle, element: export, verb: .click, effect: nil, windowTitleAfter: nil))
        await memory.record(ActionRecord(bundleID: bundle, element: export, verb: .click,
                                         effect: .stateFlip(from: .off, to: .on), windowTitleAfter: nil))
        let knowledge = await store.load(bundleID: bundle)
        #expect(knowledge?.brain.transitions.isEmpty ?? true)
    }

    @Test("enrich annotates a scene from the brain and returns the same scene when it has nothing to add")
    func enrich() async throws {
        let store = InMemoryKnowledgeStore()
        let memory = memory(store)
        let untouched = scene([export])
        #expect(await memory.enrich(untouched) == untouched)
        try await memory.observe(untouched)
        let record = ActionRecord(bundleID: bundle, element: export, verb: .click,
                                  effect: .menuOpened(labels: ["Queue"]), windowTitleAfter: nil)
        await memory.record(record)
        let enriched = await memory.enrich(untouched)
        #expect(enriched.elements[0].does == "click: opens menu(Queue)")
        #expect(enriched.elements[0].bounds == export.bounds)
        #expect(enriched.token == untouched.token, "an annotation never moves the token an action must echo")
    }
}

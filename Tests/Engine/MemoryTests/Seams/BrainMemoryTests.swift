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

    @Test("each verb keeps its own expectations: a click, a double-click and a set_toggle never answer for another")
    func expectationsPerVerb() async throws {
        let store = InMemoryKnowledgeStore()
        let memory = memory(store)
        try await memory.observe(scene([export, platform]))
        let menu = SceneEffect.menuOpened(labels: ["H.264", "ProRes"])
        let window = SceneEffect.windowTitleChanged(title: "Queue")
        await memory.record(ActionRecord(bundleID: bundle, element: export, verb: .click, effect: menu,
                                         windowTitleAfter: nil))
        for _ in 0..<2 {
            await memory.record(ActionRecord(bundleID: bundle, element: export, verb: .doubleClick, effect: window,
                                             windowTitleAfter: "Queue"))
        }
        #expect(await memory.expectedEffect(of: .click, on: export, in: bundle) == menu)
        #expect(await memory.expectedEffect(of: .doubleClick, on: export, in: bundle) == window)
        #expect(await memory.expectedEffect(of: .rightClick, on: export, in: bundle) == nil)
        #expect(await memory.expectedEffect(of: .setToggle, on: export, in: bundle) == nil)
        let brain = try #require(await store.load(bundleID: bundle)).brain
        #expect(brain.transitions.map(\.verb) == [.click, .doubleClick])
        #expect(brain.transitions.map(\.trigger) == [.click, .click],
                "the trigger an older build reads is still written")
    }

    @Test("a stored click of unknown verb is kept and shown apart, and is evidence of no verb")
    func legacyTransitions() async throws {
        let store = InMemoryKnowledgeStore()
        let memory = memory(store)
        try await memory.observe(scene([export]))
        let key = try #require(await store.mutate(bundleID: bundle) { knowledge -> String? in
            guard case .found(let key) = BrainMatcher.match(BrainDetection(export), in: knowledge.brain) else {
                return nil
            }
            knowledge.brain.transitions += [
                LearnedTransition(anchorKey: key, trigger: .click, effect: "menuOpened:A|B", evidence: 3,
                                  lastObserved: Fixtures.t0),
                LearnedTransition(anchorKey: key, trigger: .rightClick, effect: "menuOpened:Copy|Paste", evidence: 2,
                                  lastObserved: Fixtures.t0),
            ]
            return key
        })
        for verb in [ActionVerb.click, .doubleClick, .setToggle] {
            #expect(await memory.expectedEffect(of: verb, on: export, in: bundle) == nil, "\(verb)")
        }
        #expect(await memory.expectedEffect(of: .rightClick, on: export, in: bundle)
                == .menuOpened(labels: ["Copy", "Paste"]), "a stored right-click had one producer")
        #expect(await memory.enrich(scene([export])).elements[0].does
                == "click (verb unknown): opens menu(A|B) · right_click: opens menu(Copy|Paste)")

        await memory.record(ActionRecord(bundleID: bundle, element: export, verb: .click,
                                         effect: .menuOpened(labels: ["A", "B"]), windowTitleAfter: nil))
        await memory.record(ActionRecord(bundleID: bundle, element: export, verb: .rightClick,
                                         effect: .menuOpened(labels: ["Copy", "Paste"]), windowTitleAfter: nil))
        let brain = try #require(await store.load(bundleID: bundle)).brain
        let edges = brain.transitions.filter { $0.anchorKey == key }
        #expect(edges.map(\.verb) == [nil, .rightClick, .click], "the unknown click is never merged into a verb")
        #expect(edges.map(\.evidence) == [3, 3, 1])

        let legacy = #"{"anchorKey":"k","trigger":"click","effect":"menuOpened:A|B","evidence":2,"#
            + #""lastObserved":"2026-07-02T10:00:00.000Z"}"#
        let decoded = try KnowledgeCoding.makeDecoder().decode(LearnedTransition.self, from: Data(legacy.utf8))
        #expect(decoded.verb == nil && decoded.attributedVerb == nil && decoded.producer == "click (verb unknown)")
        let written = try JSONSerialization.jsonObject(with: KnowledgeCoding.makeEncoder().encode(edges[2]))
        let fields = try #require(written as? [String: Any])
        #expect(fields["trigger"] as? String == "click" && fields["verb"] as? String == "click")
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

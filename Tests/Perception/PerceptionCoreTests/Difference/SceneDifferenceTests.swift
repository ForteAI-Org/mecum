//
//  SceneDifferenceTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

@testable import PerceptionCore
import Testing

/// The differ names causality from text, so its rules are pinned on scene pairs shaped like the
/// measurements that produced them: a flipped switch, an opened menu, meter noise, title churn.
@Suite("Scene difference")
struct SceneDifferenceTests {

    private func scene(_ elements: [SceneElement], title: String = "Export") -> SceneSnapshot {
        SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements
        )
    }

    private func element(_ id: String, _ label: String, kind: ElementKind = .control,
                         x: Double = 0.2, y: Double = 0.2, state: ControlState? = nil) -> SceneElement {
        SceneElement(id: id, kind: kind, label: label, bounds: NormalizedRect(x: x, y: y, width: 0.05, height: 0.02), state: state)
    }

    @Test("a state flip on the target")
    func stateFlipOnTarget() {
        let before = scene([element("sw", "Facebook", state: .off)])
        let after  = scene([element("sw", "Facebook", state: .on)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: "sw") == .stateFlip(from: .off, to: .on))
    }

    @Test("a state flip survives id churn through kind and label")
    func stateFlipSurvivesIDChurn() {
        let before = scene([element("sw1", "Facebook", state: .off)])
        let after  = scene([element("sw2", "Facebook", x: 0.201, state: .on)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: "sw1") == .stateFlip(from: .off, to: .on))
    }

    @Test("a clustered appearance is a menu, with sorted labels")
    func menuOpened() {
        let before = scene([element("t", "Sequence", kind: .text)])
        let after  = scene([element("t", "Sequence", kind: .text),
                            element("m1", "Cut", kind: .text, x: 0.30, y: 0.30),
                            element("m2", "Copy", kind: .text, x: 0.30, y: 0.33),
                            element("m3", "Paste", kind: .text, x: 0.30, y: 0.36)])
        let effect = SceneDifference.effect(before: before, after: after, targetID: "t")
        #expect(effect == .menuOpened(labels: ["Copy", "Cut", "Paste"]))
        #expect(effect?.encoded == "menuOpened:Copy|Cut|Paste")
    }

    @Test("scattered new elements are an appearance, not a menu")
    func scatteredAppearance() {
        let before = scene([element("t", "Sequence", kind: .text)])
        let after  = scene([element("t", "Sequence", kind: .text),
                            element("m1", "Alpha", x: 0.05, y: 0.05),
                            element("m2", "Beta", x: 0.90, y: 0.10),
                            element("m3", "Gamma", x: 0.10, y: 0.90)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil)
                == .elementsAppeared(labels: ["Alpha", "Beta", "Gamma"]))
    }

    @Test("live measurements are not UI")
    func measurementsAreNotUI() {
        let before = scene([element("t", "Sequence", kind: .text)])
        let after  = scene([element("t", "Sequence", kind: .text),
                            element("m1", "+17.6 db", x: 0.3, y: 0.3),
                            element("m2", "00:00:12:00", x: 0.3, y: 0.35),
                            element("m3", "2827313", x: 0.3, y: 0.4),
                            element("m4", "-Od", x: 0.3, y: 0.45)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil) == nil)
    }

    @Test("the same action produces the same encoded effect")
    func sameActionSameEffect() {
        let before = scene([element("t", "Track", kind: .text)])
        let first = scene([element("t", "Track", kind: .text),
                           element("x1", "Hide", x: 0.3, y: 0.30), element("x2", "Hide All Tracks", x: 0.3, y: 0.33),
                           element("x3", "New Track", x: 0.3, y: 0.36), element("noise", "+3.3 db", x: 0.3, y: 0.39)])
        let second = scene([element("t", "Track", kind: .text),
                            element("y9", "New Track", x: 0.302, y: 0.36), element("y7", "Hide", x: 0.301, y: 0.30),
                            element("y8", "Hide All Tracks", x: 0.3, y: 0.33), element("noise", "-17.9 db", x: 0.3, y: 0.4)])
        let e1 = SceneDifference.effect(before: before, after: first, targetID: nil)
        let e2 = SceneDifference.effect(before: before, after: second, targetID: nil)
        #expect(e1 != nil)
        #expect(e1 == e2)
    }

    @Test("a jittered relabel is not an appearance")
    func jitteredRelabelIsNotNew() {
        let before = scene([element("a1", "Export")])
        let after  = scene([element("a2", "Export", x: 0.202)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil) == nil)
    }

    @Test("a closed menu is a disappearance")
    func menuClosed() {
        let before = scene([element("t", "Sequence", kind: .text), element("m1", "Cut", kind: .text),
                            element("m2", "Copy", kind: .text), element("m3", "Paste", kind: .text)])
        let after  = scene([element("t", "Sequence", kind: .text)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil)
                == .elementsDisappeared(labels: ["Copy", "Cut", "Paste"]))
    }

    @Test("a title change wins over everything")
    func titleChangeWins() {
        let before = scene([element("sw", "Facebook", state: .off)], title: "Export")
        let after  = scene([element("sw", "Facebook", state: .on)], title: "Render Queue")
        #expect(SceneDifference.effect(before: before, after: after, targetID: "sw") == .windowTitleChanged(title: "Render Queue"))
    }

    @Test("a counter in the title is not a change")
    func titleCounterChurn() {
        let before = scene([element("a", "Export")], title: "Project v4")
        let after  = scene([element("a", "Export")], title: "Project v5")
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil) == nil)
    }

    @Test("no change is nil")
    func noChange() {
        let before = scene([element("a", "Export"), element("sw", "Facebook", state: .off)])
        #expect(SceneDifference.effect(before: before, after: before, targetID: "a") == nil)
    }

    @Test("family, summary and round trip through the encoded string")
    func familySummaryAndRoundTrip() {
        let flip = SceneEffect.stateFlip(from: .off, to: .on)
        #expect(flip.family == "stateFlip")
        #expect(flip.summary == "toggles")
        #expect(SceneEffect.menuOpened(labels: ["Copy", "Cut", "Paste", "Undo"]).summary == "opens menu(Copy|Cut|Paste…)")
        #expect(SceneEffect.windowTitleChanged(title: "Render Queue").summary == "navigates to Render Queue")
        #expect(SceneEffect.stateFlip(from: .on, to: .off).family == flip.family)
        for effect in [flip, SceneEffect.menuOpened(labels: ["A", "B"]), .elementsAppeared(labels: ["X"]),
                       .elementsDisappeared(labels: []), .windowTitleChanged(title: "Q")] {
            #expect(SceneEffect(encoded: effect.encoded) == effect)
        }
        #expect(SceneEffect(encoded: "nonsense:x") == nil)
    }
}

//
//  SceneDifferenceTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation
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

    @Test("native selection identifies the field even beside a checkbox with the same ID",
          arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func nativeSelectionBesideASharedID(_ role: String) {
        var field = element("search", "Search #2")
        field.role = role
        field.value = "Aé🧪"
        field.selectedRange = NSRange(location: 0, length: 0)
        var selected = field
        selected.selectedRange = NSRange(location: 0, length: 4)
        var checkbox = element("search", "Search", state: .on)
        checkbox.role = "AXCheckBox"
        #expect(SceneDifference.effect(
            before: scene([checkbox, field]), after: scene([checkbox, selected]), targetID: nil
        ) == .textSelectionChanged)
    }

    @Test("a selection cannot be attributed across a different application or document")
    func nativeSelectionNeedsTheSameWindow() {
        var field = element("name", "Name")
        field.role = "AXTextField"
        field.value = "Aé🧪"
        field.selectedRange = NSRange(location: 0, length: 0)
        var selected = field
        selected.selectedRange = NSRange(location: 0, length: 4)
        let before = scene([field], title: "Untitled-1")
        var otherDocument = scene([selected], title: "Untitled-2")
        #expect(SceneDifference.effect(before: before, after: otherDocument, targetID: nil) == nil)
        otherDocument.bundleID = "com.other"
        otherDocument.windowTitle = before.windowTitle
        #expect(SceneDifference.effect(before: before, after: otherDocument, targetID: nil) == nil)
    }

    @Test("a text field's new value is an effect only when the caller counts it")
    func valueChangeIsOptIn() {
        var field = element("name", "First Text View")
        field.role = "AXTextArea"
        field.value = ""
        var typed = field
        typed.value = "a"
        let before = scene([field]), after = scene([typed])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil) == nil)
        let effect = SceneDifference.effect(before: before, after: after, targetID: nil, countsValueChange: true)
        #expect(effect == .valueChanged(label: "First Text View", value: "a"))
        #expect(effect?.summary == "'First Text View' now reads 'a'")
    }

    @Test("a value needs a text field, one match each side and a readable value on both")
    func valueChangeNeedsAReadableMatchedField() {
        var field = element("name", "Name")
        field.role = "AXTextField"
        field.value = "x"
        var changed = field
        changed.value = "y"
        func effect(_ old: [SceneElement], _ new: [SceneElement]) -> SceneEffect? {
            SceneDifference.effect(before: scene(old), after: scene(new), targetID: nil, countsValueChange: true)
        }
        var unreadable = field
        unreadable.value = nil
        #expect(effect([unreadable], [changed]) == nil)
        #expect(effect([field], [unreadable]) == nil)
        #expect(effect([field, field], [changed, changed]) == nil)
        var other = changed
        other.id = "another"
        #expect(effect([field], [other]) == nil)
        var label = changed
        label.role = "AXStaticText"
        var staticOld = field
        staticOld.role = "AXStaticText"
        #expect(effect([staticOld], [label]) == nil)
        // A caret move with the same value keeps its own effect.
        var moved = field
        moved.selectedRange = NSRange(location: 1, length: 0)
        var start = field
        start.selectedRange = NSRange(location: 0, length: 0)
        #expect(effect([start], [moved]) == .textSelectionChanged)
    }

    @Test("a value change summary is shortened and survives the encoded round trip")
    func valueChangeSummaryAndRoundTrip() {
        let long = SceneEffect.valueChanged(label: "Notes", value: String(repeating: "x", count: 80))
        #expect(long.summary == "'Notes' now reads '" + String(repeating: "x", count: 59) + "…'")
        let effect = SceneEffect.valueChanged(label: "Name", value: "a|b>c:d")
        #expect(effect.family == "valueChanged")
        #expect(SceneEffect(encoded: effect.encoded) == effect)
        #expect(SceneEffect(encoded: "valueChanged:no separator") == nil)
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
                       .elementsDisappeared(labels: []), .windowTitleChanged(title: "Q"), .textSelectionChanged] {
            #expect(SceneEffect(encoded: effect.encoded) == effect)
        }
        #expect(SceneEffect(encoded: "nonsense:x") == nil)
        #expect(SceneEffect(encoded: "textSelectionChanged:unknown") == nil)
    }
}

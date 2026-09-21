import XCTest
@testable import LocatorCore

final class SceneDiffTests: XCTestCase {
    private func scene(_ elements: [SceneElement], title: String = "Export") -> SceneSnapshot {
        SceneSnapshot(bundleID: "com.x", app: "X", windowTitle: title, viewportPx: [1000, 800],
                      elements: elements, commands: [])
    }
    private func el(_ id: String, _ label: String, kind: String = "control",
                    x: Double = 0.2, y: Double = 0.2, state: String? = nil) -> SceneElement {
        SceneElement(id: id, kind: kind, label: label, pos: [x, y, 0.05, 0.02], state: state)
    }

    func testStateFlipOnTheTarget() {
        let b = scene([el("sw", "Facebook", state: "off")])
        let a = scene([el("sw", "Facebook", state: "on")])
        XCTAssertEqual(SceneDiff.effect(before: b, after: a, targetID: "sw", point: CGPoint(x: 0.22, y: 0.21)),
                       "stateFlip:off>on")
    }

    func testStateFlipSurvivesIdChurn() {   // pos-bucket jitter renames the id; label+kind rescue it
        let b = scene([el("sw1", "Facebook", state: "off")])
        let a = scene([el("sw2", "Facebook", x: 0.201, state: "on")])
        XCTAssertEqual(SceneDiff.effect(before: b, after: a, targetID: "sw1", point: nil), "stateFlip:off>on")
    }

    func testMenuOpened() {
        let b = scene([el("t", "Sequence", kind: "text")])
        let a = scene([el("t", "Sequence", kind: "text"),
                       el("m1", "Cut", kind: "text", x: 0.30, y: 0.30),
                       el("m2", "Copy", kind: "text", x: 0.30, y: 0.33),
                       el("m3", "Paste", kind: "text", x: 0.30, y: 0.36)])
        XCTAssertEqual(SceneDiff.effect(before: b, after: a, targetID: "t", point: CGPoint(x: 0.3, y: 0.3)),
                       "menuOpened:Copy|Cut|Paste")   // sorted → stable effect string across observations
    }

    func testScatteredNewElementsAreAppearedNotMenu() {
        let b = scene([el("t", "Sequence", kind: "text")])
        let a = scene([el("t", "Sequence", kind: "text"),
                       el("m1", "Alpha", x: 0.05, y: 0.05),
                       el("m2", "Beta", x: 0.90, y: 0.10),
                       el("m3", "Gamma", x: 0.10, y: 0.90)])
        XCTAssertEqual(SceneDiff.effect(before: b, after: a, targetID: nil, point: nil),
                       "elementsAppeared:Alpha|Beta|Gamma")
    }

    func testLiveMeasurementsAreNotUI() {   // measured on Pro Tools: meters/dB/timecodes repaint every frame
        let b = scene([el("t", "Sequence", kind: "text")])
        let a = scene([el("t", "Sequence", kind: "text"),
                       el("m1", "+17.6 db", x: 0.3, y: 0.3),
                       el("m2", "00:00:12:00", x: 0.3, y: 0.35),
                       el("m3", "2827313", x: 0.3, y: 0.4),
                       el("m4", "-Od", x: 0.3, y: 0.45)])
        XCTAssertNil(SceneDiff.effect(before: b, after: a, targetID: nil, point: nil))   // pure noise → no transition
    }

    func testSameActionProducesTheSameEffectString() {   // what lets evidence accumulate to trusted
        let b = scene([el("t", "Track", kind: "text")])
        let a1 = scene([el("t", "Track", kind: "text"),
                        el("x1", "Hide", x: 0.3, y: 0.30), el("x2", "Hide All Tracks", x: 0.3, y: 0.33),
                        el("x3", "New Track", x: 0.3, y: 0.36), el("noise", "+3.3 db", x: 0.3, y: 0.39)])
        let a2 = scene([el("t", "Track", kind: "text"),
                        el("y9", "New Track", x: 0.302, y: 0.36), el("y7", "Hide", x: 0.301, y: 0.30),
                        el("y8", "Hide All Tracks", x: 0.3, y: 0.33), el("noise", "-17.9 db", x: 0.3, y: 0.4)])
        let e1 = SceneDiff.effect(before: b, after: a1, targetID: nil, point: nil)
        let e2 = SceneDiff.effect(before: b, after: a2, targetID: nil, point: nil)
        XCTAssertNotNil(e1)
        XCTAssertEqual(e1, e2)   // different ids, different order, different meter noise → SAME canonical effect
    }

    func testJitteredRelabelIsNotNew() {   // same label, new id (moved a pixel) — no phantom appearance
        let b = scene([el("a1", "Export")])
        let a = scene([el("a2", "Export", x: 0.202)])
        XCTAssertNil(SceneDiff.effect(before: b, after: a, targetID: nil, point: nil))
    }

    func testMenuClosedIsDisappeared() {
        let b = scene([el("t", "Sequence", kind: "text"),
                       el("m1", "Cut", kind: "text"), el("m2", "Copy", kind: "text"), el("m3", "Paste", kind: "text")])
        let a = scene([el("t", "Sequence", kind: "text")])
        XCTAssertEqual(SceneDiff.effect(before: b, after: a, targetID: nil, point: nil), "elementsDisappeared:Copy|Cut|Paste")
    }

    func testTitleChangeWinsOverEverything() {
        let b = scene([el("sw", "Facebook", state: "off")], title: "Export")
        let a = scene([el("sw", "Facebook", state: "on")], title: "Render Queue")
        XCTAssertEqual(SceneDiff.effect(before: b, after: a, targetID: "sw", point: nil),
                       "windowTitleChanged:Render Queue")
    }

    func testTitleCounterChurnIsNotAChange() {   // "Untitled - Edited" vs "Untitled" families differ… use numerics
        let b = scene([el("a", "Export")], title: "Project v4")
        let a = scene([el("a", "Export")], title: "Project v5")
        XCTAssertNil(SceneDiff.effect(before: b, after: a, targetID: nil, point: nil))
    }

    func testNoChangeIsNil() {
        let b = scene([el("a", "Export"), el("sw", "Facebook", state: "off")])
        XCTAssertNil(SceneDiff.effect(before: b, after: b, targetID: "a", point: nil))
    }

    func testFamilyAndSummary() {
        XCTAssertEqual(SceneDiff.family("stateFlip:off>on"), "stateFlip")
        XCTAssertEqual(SceneDiff.family("menuOpened:A|B"), "menuOpened")
        XCTAssertEqual(SceneDiff.summary("stateFlip:off>on"), "toggles")
        XCTAssertEqual(SceneDiff.summary("menuOpened:Copy|Cut|Paste|Undo"), "opens menu(Copy|Cut|Paste…)")
        XCTAssertEqual(SceneDiff.summary("windowTitleChanged:Render Queue"), "navigates to Render Queue")
        // family compare is how act verifies: direction/items may differ, the KIND must not
        XCTAssertEqual(SceneDiff.family("stateFlip:on>off"), SceneDiff.family("stateFlip:off>on"))
    }

    func testDoesAnnotationRequiresEvidence() {
        var brain = UIBrain()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        brain.objects.append(UIObjectAnchor(anchorKey: "k", kind: "control", label: "Facebook",
                                            boundsTypical: [0.2, 0.2, 0.05, 0.02], firstSeen: t0, lastSeen: t0))
        _ = BrainUpdater.recordTransition(anchorKey: "k", trigger: "click", effect: "stateFlip:off>on", into: &brain, now: t0)
        XCTAssertNil(brain.does(anchorKey: "k"))                     // one sighting is not causality
        _ = BrainUpdater.recordTransition(anchorKey: "k", trigger: "click", effect: "stateFlip:off>on", into: &brain, now: t0)
        XCTAssertEqual(brain.does(anchorKey: "k"), "click: toggles") // trusted at evidence 2
        // and enrich carries it onto the matching scene element
        let el = SceneElement(id: "x", kind: "control", label: "Facebook", pos: [0.2, 0.2, 0.05, 0.02], state: "off")
        XCTAssertEqual(brain.enrich([el])[0].does, "click: toggles")
    }

    func testTransitionEvidenceAccumulates() {
        var brain = UIBrain()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(BrainUpdater.recordTransition(anchorKey: "k", trigger: "click", effect: "stateFlip:off>on",
                                                     into: &brain, now: t0), 1)
        XCTAssertEqual(BrainUpdater.recordTransition(anchorKey: "k", trigger: "click", effect: "stateFlip:off>on",
                                                     into: &brain, now: t0), 2)
        XCTAssertEqual(BrainUpdater.recordTransition(anchorKey: "k", trigger: "click", effect: "stateFlip:on>off",
                                                     into: &brain, now: t0), 1)   // a different effect is a new edge
        XCTAssertEqual(brain.transitions.count, 2)
    }
}

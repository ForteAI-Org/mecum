import XCTest
@testable import LocatorCore

final class SceneResolveTests: XCTestCase {
    private func scene(_ elements: [SceneElement]) -> SceneSnapshot {
        SceneSnapshot(bundleID: "com.x", app: "X", windowTitle: "W", viewportPx: [1000, 800],
                      elements: elements, commands: [])
    }

    func testIdWinsOverLabel() {
        let s = scene([SceneElement(id: "aa", kind: "control", label: "Export", pos: [0, 0, 0.1, 0.1]),
                       SceneElement(id: "bb", kind: "text", label: "aa", pos: [0.5, 0, 0.1, 0.1])])
        guard case .found(let e) = s.resolve(target: "aa") else { return XCTFail() }
        XCTAssertEqual(e.id, "aa")
    }

    func testUniqueLabelCaseInsensitive() {
        let s = scene([SceneElement(id: "aa", kind: "control", label: "Export", pos: [0, 0, 0.1, 0.1])])
        guard case .found(let e) = s.resolve(target: "export") else { return XCTFail() }
        XCTAssertEqual(e.id, "aa")
    }

    func testSharedRowNamePrefersTheStatefulSwitchForSetToggle() {
        // By design a row yields TWO same-label elements: the logo composite and the switch.
        let s = scene([SceneElement(id: "logo", kind: "control", label: "Facebook", pos: [0.05, 0.3, 0.1, 0.02]),
                       SceneElement(id: "sw", kind: "control", label: "Facebook", pos: [0.23, 0.3, 0.03, 0.02], state: "off")])
        guard case .found(let e) = s.resolve(target: "Facebook", preferStateful: true) else { return XCTFail() }
        XCTAssertEqual(e.id, "sw")
        // A plain click on the same name stays ambiguous — the caller must pick an id.
        guard case .ambiguous(2) = s.resolve(target: "Facebook") else { return XCTFail() }
    }

    func testAmbiguousWhenSeveralStatefulMatch() {
        let s = scene([SceneElement(id: "a", kind: "control", label: "VIDEO", pos: [0.2, 0.3, 0.03, 0.02], state: "on"),
                       SceneElement(id: "b", kind: "control", label: "VIDEO", pos: [0.6, 0.3, 0.03, 0.02], state: "off")])
        guard case .ambiguous(2) = s.resolve(target: "VIDEO", preferStateful: true) else { return XCTFail() }
    }

    func testResolvesDisplayStringWithStateAnnotation() {
        // The map renders state as a trailing " [off]"; a model that echoes "Vimeo [off]" must still hit
        // the "Vimeo" element (measured: Premiere "activate vimeo" honest-missed on the display string).
        let s = scene([SceneElement(id: "v", kind: "control", label: "Vimeo", pos: [0.2, 0.3, 0.03, 0.02], state: "off")])
        guard case .found(let e) = s.resolve(target: "Vimeo [off]", preferStateful: true) else { return XCTFail() }
        XCTAssertEqual(e.id, "v")
        // A group-ordinal annotation is peeled too.
        guard case .found = s.resolve(target: "Vimeo (row#6)") else { return XCTFail("ordinal annotation") }
        // Exact match still wins and a real parenthetical label isn't clobbered by the fallback.
        let s2 = scene([SceneElement(id: "p", kind: "control", label: "Save (All)", pos: [0, 0, 0.1, 0.1])])
        guard case .found(let e2) = s2.resolve(target: "Save (All)") else { return XCTFail() }
        XCTAssertEqual(e2.id, "p")
    }

    func testDisambiguationListsCandidateIds() {
        // Two "Export" (a top tab + a footer button) — the ambiguous message must list ids so the model
        // can pick the button (measured: Premiere Export tab vs Export button).
        let s = SceneSnapshot(bundleID: "com.x", app: "X", windowTitle: "W", viewportPx: [1000, 800], elements: [
            SceneElement(id: "tab", kind: "control", label: "Export", pos: [0.32, 0.02, 0.06, 0.02], section: "region 1"),
            SceneElement(id: "btn", kind: "control", label: "Export", pos: [0.88, 0.95, 0.08, 0.03], section: "footer"),
        ], commands: [])
        guard case .ambiguous(2) = s.resolve(target: "Export") else { return XCTFail() }
        let d = s.disambiguation(target: "Export")
        XCTAssertTrue(d.contains("section:'region 1'") && d.contains("section:'footer'"))
        // The section arg resolves the collision even though both ids are identical.
        guard case .found(let e) = s.resolve(target: "Export", section: "footer") else { return XCTFail() }
        XCTAssertEqual(e.id, "btn")
        guard case .found(let e2) = s.resolve(target: "Export", section: "region 1") else { return XCTFail() }
        XCTAssertEqual(e2.id, "tab")
    }

    func testGrepFindsGoalThroughOCRJunkAndFiller() {
        // The gemma failure: goal "Simone chat", scene has sidebar item OCR'd as "Ze Simone" — grep
        // must surface it as the unique top hit (filler "chat" doesn't punish; control beats prose).
        let s = SceneSnapshot(bundleID: "com.x", app: "Slack", windowTitle: "W", viewportPx: [1000, 800], elements: [
            SceneElement(id: "sb", kind: "control", label: "Ze Simone", pos: [0.1, 0.9, 0.1, 0.02], section: "Fritz"),
            SceneElement(id: "msg", kind: "text", label: "ho parlato con simone ieri di quel bug", pos: [0.5, 0.4, 0.4, 0.02], section: "chat"),
            SceneElement(id: "other", kind: "control", label: "Michele", pos: [0.1, 0.8, 0.1, 0.02], section: "Fritz"),
        ], commands: [])
        let hits = s.grep(goal: "Simone chat")
        XCTAssertEqual(hits.first?.element.id, "sb")
        XCTAssertTrue(hits.first!.score > hits.dropFirst().first!.score)   // UNIQUE top → clickable
        XCTAssertTrue(s.grep(goal: "vai da simone").first?.element.id == "sb")  // Italian filler stripped
        XCTAssertTrue(s.grep(goal: "loris").isEmpty)                        // absent goal → no invention
    }

    func testCoreLabelTierSurvivesOCRJunkAndPunctuation() {
        // The avatar glyph fuses into a DIFFERENT prefix every frame; channel names carry punctuation.
        let s = scene([SceneElement(id: "sim", kind: "control", label: "Za Simone", pos: [0.1, 0.9, 0.1, 0.02]),
                       SceneElement(id: "ch", kind: "text", label: "#_all-team", pos: [0.1, 0.4, 0.1, 0.02])])
        guard case .found(let e1) = s.resolve(target: "Simone") else { return XCTFail("junk prefix") }
        XCTAssertEqual(e1.id, "sim")
        guard case .found(let e1b) = s.resolve(target: "Ze Simone") else { return XCTFail("stored junk label") }
        XCTAssertEqual(e1b.id, "sim")   // a route step saved with OLD junk still replays
        guard case .found(let e2) = s.resolve(target: "all team") else { return XCTFail("punctuation") }
        XCTAssertEqual(e2.id, "ch")
        // Exact matches still take precedence over core matches (no regression).
        let s2 = scene([SceneElement(id: "a", kind: "control", label: "Simone", pos: [0, 0, 0.1, 0.1]),
                        SceneElement(id: "b", kind: "control", label: "Za Simone", pos: [0.5, 0, 0.1, 0.1])])
        guard case .found(let e3) = s2.resolve(target: "Simone") else { return XCTFail() }
        XCTAssertEqual(e3.id, "a")
    }

    func testMissingTarget() {
        guard case .none = scene([]).resolve(target: "nope") else { return XCTFail() }
    }
}

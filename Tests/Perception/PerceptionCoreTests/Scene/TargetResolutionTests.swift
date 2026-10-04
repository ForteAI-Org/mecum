//
//  TargetResolutionTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import PerceptionCore
import Testing

/// Resolution is where a model's word meets a screen. Each rule below was earned by a session that
/// failed without it: shared row names, map annotations echoed back, junk prefixes, two "Export"s.
@Suite("Target resolution")
struct TargetResolutionTests {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    private func scene(_ elements: [SceneElement]) -> SceneSnapshot {
        SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: "W",
            viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements
        )
    }

    @Test("an id wins over a label")
    func idWinsOverLabel() throws {
        let s = scene([SceneElement(id: "aa", kind: .control, label: "Export", bounds: rect(0, 0, 0.1, 0.1)),
                       SceneElement(id: "bb", kind: .text, label: "aa", bounds: rect(0.5, 0, 0.1, 0.1))])
        guard case .found(let element) = s.resolve(target: "aa") else { Issue.record("not found"); return }
        #expect(element.id == "aa")
    }

    @Test("a unique label matches case-insensitively")
    func uniqueLabelCaseInsensitive() {
        let s = scene([SceneElement(id: "aa", kind: .control, label: "Export", bounds: rect(0, 0, 0.1, 0.1))])
        guard case .found(let element) = s.resolve(target: "export") else { Issue.record("not found"); return }
        #expect(element.id == "aa")
    }

    @Test("a shared row name prefers the stateful switch for a toggle, and stays ambiguous for a click")
    func sharedRowNamePrefersStateful() {
        let s = scene([SceneElement(id: "logo", kind: .control, label: "Facebook", bounds: rect(0.05, 0.3, 0.1, 0.02)),
                       SceneElement(id: "sw", kind: .control, label: "Facebook", bounds: rect(0.23, 0.3, 0.03, 0.02), state: .off)])
        guard case .found(let element) = s.resolve(target: "Facebook", preferStateful: true) else { Issue.record("not found"); return }
        #expect(element.id == "sw")
        #expect(s.resolve(target: "Facebook") == .ambiguous(2))
    }

    @Test("several stateful matches stay ambiguous")
    func severalStatefulStayAmbiguous() {
        let s = scene([SceneElement(id: "a", kind: .control, label: "VIDEO", bounds: rect(0.2, 0.3, 0.03, 0.02), state: .on),
                       SceneElement(id: "b", kind: .control, label: "VIDEO", bounds: rect(0.6, 0.3, 0.03, 0.02), state: .off)])
        #expect(s.resolve(target: "VIDEO", preferStateful: true) == .ambiguous(2))
    }

    @Test("a display string with annotations still resolves")
    func displayStringResolves() {
        let s = scene([SceneElement(id: "v", kind: .control, label: "Vimeo", bounds: rect(0.2, 0.3, 0.03, 0.02), state: .off)])
        guard case .found(let element) = s.resolve(target: "Vimeo [off]", preferStateful: true) else { Issue.record("state"); return }
        #expect(element.id == "v")
        guard case .found = s.resolve(target: "Vimeo (row#6)") else { Issue.record("ordinal"); return }
        let s2 = scene([SceneElement(id: "p", kind: .control, label: "Save (All)", bounds: rect(0, 0, 0.1, 0.1))])
        guard case .found(let exact) = s2.resolve(target: "Save (All)") else { Issue.record("exact"); return }
        #expect(exact.id == "p")
    }

    @Test("disambiguation lists sections, and a section resolves the collision")
    func disambiguationAndSection() {
        let s = scene([
            SceneElement(id: "tab", kind: .control, label: "Export", bounds: rect(0.32, 0.02, 0.06, 0.02), section: "region 1"),
            SceneElement(id: "btn", kind: .control, label: "Export", bounds: rect(0.88, 0.95, 0.08, 0.03), section: "footer"),
        ])
        #expect(s.resolve(target: "Export") == .ambiguous(2))
        let hint = s.disambiguation(target: "Export")
        #expect(hint.contains("section:'region 1'") && hint.contains("section:'footer'"))
        guard case .found(let button) = s.resolve(target: "Export", section: "footer") else { Issue.record("footer"); return }
        #expect(button.id == "btn")
        guard case .found(let tab) = s.resolve(target: "Export", section: "region 1") else { Issue.record("region"); return }
        #expect(tab.id == "tab")
    }

    @Test("a shared ID diagnostic names its field and toggle candidates")
    func sharedIDDisambiguation() {
        let field = SceneElement(id: "control|search", kind: .control, label: "Search #2",
                                 bounds: rect(0.40, 0.16, 0.4, 0.04), role: "AXTextField")
        let toggle = SceneElement(id: field.id, kind: .control, label: "Search",
                                  bounds: rect(0.8, 0.04, 0.1, 0.02), role: "AXCheckBox", state: .on)
        let s = scene([field, toggle])
        #expect(s.candidates(target: field.id) == [field, toggle])
        let hint = s.disambiguation(target: field.id)
        #expect(hint.contains("Search #2") && hint.contains("AXTextField"))
        #expect(hint.contains("AXCheckBox") && hint.contains("@0.80,0.04"))
    }

    @Test("grep finds the goal through recognizer junk and filler")
    func grepThroughJunkAndFiller() throws {
        let s = scene([
            SceneElement(id: "sb", kind: .control, label: "Ze Simone", bounds: rect(0.1, 0.9, 0.1, 0.02), section: "Fritz"),
            SceneElement(id: "msg", kind: .text, label: "ho parlato con simone ieri di quel bug", bounds: rect(0.5, 0.4, 0.4, 0.02), section: "chat"),
            SceneElement(id: "other", kind: .control, label: "Michele", bounds: rect(0.1, 0.8, 0.1, 0.02), section: "Fritz"),
        ])
        let filler: Set<String> = ["chat", "vai", "da", "go", "to"]
        let hits = s.grep(goal: "Simone chat", stopwords: filler)
        #expect(hits.first?.element.id == "sb")
        let top = try #require(hits.first), second = try #require(hits.dropFirst().first)
        #expect(top.score > second.score)
        #expect(s.grep(goal: "vai da simone", stopwords: filler).first?.element.id == "sb")
        #expect(s.grep(goal: "loris", stopwords: filler).isEmpty)
    }

    @Test("the core-label tier survives junk prefixes and punctuation")
    func coreLabelTier() {
        let s = scene([SceneElement(id: "sim", kind: .control, label: "Za Simone", bounds: rect(0.1, 0.9, 0.1, 0.02)),
                       SceneElement(id: "ch", kind: .text, label: "#_all-team", bounds: rect(0.1, 0.4, 0.1, 0.02))])
        guard case .found(let a) = s.resolve(target: "Simone") else { Issue.record("junk prefix"); return }
        #expect(a.id == "sim")
        guard case .found(let b) = s.resolve(target: "Ze Simone") else { Issue.record("stored junk"); return }
        #expect(b.id == "sim")
        guard case .found(let c) = s.resolve(target: "all team") else { Issue.record("punctuation"); return }
        #expect(c.id == "ch")
        let s2 = scene([SceneElement(id: "a", kind: .control, label: "Simone", bounds: rect(0, 0, 0.1, 0.1)),
                        SceneElement(id: "b", kind: .control, label: "Za Simone", bounds: rect(0.5, 0, 0.1, 0.1))])
        guard case .found(let exact) = s2.resolve(target: "Simone") else { Issue.record("exact"); return }
        #expect(exact.id == "a")
    }

    @Test("two detections of one widget at the same box collapse; two icons apart stay ambiguous")
    func sameRowCollapse() {
        let twice = scene([SceneElement(id: "?|@1,0", kind: .icon, label: "(unlabeled)", bounds: rect(0.10, 0.02, 0.04, 0.03), isUnlabeled: true),
                           SceneElement(id: "?|@1,0", kind: .control, label: "(unlabeled)", bounds: rect(0.105, 0.021, 0.04, 0.03), isUnlabeled: true)])
        guard case .found(let one) = twice.resolve(target: "?|@1,0") else { Issue.record("collapse"); return }
        #expect(one.kind == .control)
        let apart = scene([SceneElement(id: "?|@1,0", kind: .icon, label: "(unlabeled)", bounds: rect(0.10, 0.02, 0.03, 0.03), isUnlabeled: true),
                           SceneElement(id: "?|@1,0", kind: .icon, label: "(unlabeled)", bounds: rect(0.14, 0.02, 0.03, 0.03), isUnlabeled: true)])
        #expect(apart.resolve(target: "?|@1,0") == .ambiguous(2))
    }

    @Test("a missing target is none")
    func missingTarget() {
        #expect(scene([]).resolve(target: "nope") == .none)
    }

    @Test("text entry chooses a native field over a same-name version row while clicks, IDs and scopes remain explicit",
          arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func textEntryOverVersionRow(role: String) {
        let row = SceneElement(id: "version", kind: .control, label: "26.3",
                               bounds: rect(0.27, 0.4, 0.1, 0.04), section: "versions")
        let field = SceneElement(id: "name", kind: .control, label: "26.3",
                                 bounds: rect(0.23, 0.11, 0.5, 0.04), role: role, section: "header")
        let s = scene([row, field])
        #expect(s.resolve(target: "26.3", preferNativeControls: true) == .ambiguous(2))
        #expect(s.resolve(target: "26.3", preferNativeControls: true, preferTextEntry: true) == .found(field))
        #expect(s.resolve(target: row.id, preferTextEntry: true) == .found(row))
        #expect(s.resolve(target: "26.3", section: "versions", preferTextEntry: true) == .found(row))
        var other = field
        other.id = "other-name"
        other.bounds.x = 0.8
        #expect(scene([row, field, other]).resolve(target: "26.3", preferTextEntry: true) == .ambiguous(2))
        #expect(scene([row]).resolve(target: "26.3", preferTextEntry: true) == .found(row))
    }

    @Test("click preference uses native controls but keeps explicit IDs and section filters")
    func nativeControlOverCaption() {
        let caption = SceneElement(id: "text|create", kind: .text, label: "Create",
                                   bounds: rect(0.04, 0.30, 0.08, 0.05), section: "sentence")
        let button = SceneElement(id: "control|create", kind: .control, label: "Create",
                                  bounds: rect(0.86, 0.85, 0.08, 0.05), role: "AXButton", section: "footer")
        let s = scene([caption, button])
        #expect(s.resolve(target: "Create") == .ambiguous(2))
        #expect(s.resolve(target: "Create", preferNativeControls: true) == .found(button))
        #expect(s.resolve(target: caption.id, preferNativeControls: true) == .found(caption))
        #expect(s.resolve(target: "Create", section: "sentence", preferNativeControls: true) == .found(caption))
    }

    @Test("text entry resolves a shared field and version-row ID without discarding another real field",
          arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func textEntryWithSharedID(role: String) {
        let row = SceneElement(id: "control|263", kind: .control, label: "26.3",
                               bounds: rect(0.27, 0.4, 0.1, 0.04), section: "versions")
        let field = SceneElement(id: row.id, kind: .control, label: "26.3",
                                 bounds: rect(0.23, 0.11, 0.5, 0.04), role: role, section: "header")
        let s = scene([row, field])
        #expect(s.resolve(target: row.id, preferTextEntry: true) == .found(field))
        #expect(s.resolve(target: row.id) == .ambiguous(2))
        #expect(s.resolve(target: row.id, section: "versions", preferTextEntry: true) == .found(row))
        var other = field
        other.bounds.y = 0.8
        #expect(scene([row, field, other]).resolve(target: row.id, preferTextEntry: true) == .ambiguous(2))
    }

    @Test("two native buttons remain ambiguous even with a same-name caption")
    func duplicateNativeControls() {
        let caption = SceneElement(id: "caption", kind: .text, label: "Create", bounds: rect(0.04, 0.30, 0.1, 0.05))
        let first = SceneElement(id: "first", kind: .control, label: "Create", bounds: rect(0.2, 0.5, 0.1, 0.05), role: "AXButton")
        let second = SceneElement(id: "second", kind: .control, label: "Create", bounds: rect(0.8, 0.85, 0.1, 0.05), role: "AXButton")
        #expect(scene([caption, first, second]).resolve(target: "Create", preferNativeControls: true) == .ambiguous(2))
    }

    @Test("an inferred control alone is insufficient to discard another matching label")
    func inferredControlsAreNotNativeEvidence() {
        let caption = SceneElement(id: "caption", kind: .text, label: "Create", bounds: rect(0.04, 0.30, 0.1, 0.05))
        let inferred = SceneElement(id: "inferred", kind: .control, label: "Create", bounds: rect(0.8, 0.85, 0.1, 0.05))
        #expect(scene([caption, inferred]).resolve(target: "Create", preferNativeControls: true) == .ambiguous(2))
        #expect(scene([caption, inferred]).disambiguation(target: "Create").contains("id:'caption'"))
        #expect(!scene([caption, inferred]).disambiguation(target: "Create").contains("section:'?'"))
    }

    @Test("the smallest section and element under a point win")
    func hitTesting() {
        let s = SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: "W",
            viewportPixelSize: ViewportPixelSize(width: 100, height: 100),
            elements: [SceneElement(id: "big", kind: .text, label: "big", bounds: rect(0, 0, 1, 1)),
                       SceneElement(id: "small", kind: .control, label: "small", bounds: rect(0.4, 0.4, 0.2, 0.2))],
            sections: [SceneSection(name: "content", bounds: rect(0, 0, 1, 1)),
                       SceneSection(name: "region 1", bounds: rect(0.3, 0.3, 0.4, 0.4))]
        )
        #expect(s.element(at: CGPoint(x: 0.5, y: 0.5))?.id == "small")
        #expect(s.section(at: CGPoint(x: 0.5, y: 0.5))?.name == "region 1")
        #expect(s.section(at: CGPoint(x: 0.1, y: 0.1))?.name == "content")
    }
}

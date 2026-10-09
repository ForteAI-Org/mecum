//
//  SceneChangesTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 06/10/2026.
//

import Foundation
@testable import PerceptionCore
import Testing

/// The changes a model reads instead of a scene it already holds: only what it would see or target
/// differently, in `text()`'s own lines, and nothing for what a second reading of one screen moves.
@Suite("Scene changes")
struct SceneChangesTests {

    private static func rect(_ x: Double, _ y: Double, _ w: Double = 0.1, _ h: Double = 0.03) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    private static func element(
        _ label  : String,
        _ x      : Double,
        _ y      : Double,
        kind     : ElementKind = .control,
        section  : String? = "content",
        state    : ControlState? = nil,
        value    : String? = nil,
        group    : String? = nil
    ) -> SceneElement {
        SceneElement(
            id     : SceneIdentity.key(kind: kind, label: label, bounds: rect(x, y), isUnlabeled: false),
            kind   : kind,
            label  : label,
            bounds : rect(x, y),
            state  : state,
            value  : value,
            group  : group,
            section: section
        )
    }

    private static func icon(_ x: Double, _ y: Double, section: String? = "content") -> SceneElement {
        let bounds = rect(x, y, 0.02, 0.02)
        return SceneElement(
            id         : SceneIdentity.key(kind: .icon, label: "", bounds: bounds, isUnlabeled: true),
            kind       : .icon,
            label      : "(unlabeled)",
            bounds     : bounds,
            isUnlabeled: true,
            section    : section
        )
    }

    private static func scene(
        _ elements: [SceneElement],
        sections  : [SceneSection] = [SceneSection(name: "content", bounds: rect(0, 0, 1, 1))],
        title     : String = "Mix",
        width     : Int = 1000,
        commands  : [String] = []
    ) -> SceneSnapshot {
        SceneSnapshot(
            bundleID         : "com.example.mixer",
            appName          : "Mixer",
            windowTitle      : title,
            viewportPixelSize: ViewportPixelSize(width: width, height: 800),
            elements         : elements,
            sections         : sections,
            commands         : commands
        )
    }

    private static let rows = (0..<6).map { element("Track \($0 + 1)", 0.1, 0.1 + 0.1 * Double($0)) }

    @Test("the same elements in another order, jittered, regrouped and retagged are unchanged")
    func secondReadingOfOneScreenIsUnchanged() {
        let before = Self.scene(Self.rows + [Self.icon(0.80, 0.05)])
        var after = Self.rows.reversed().map { row -> SceneElement in
            var row = row
            row.bounds.x += 0.004
            row.bounds.y -= 0.003
            row.group = "column#\(Int(row.bounds.y * 10))"
            return row
        }
        after.append(Self.icon(0.81, 0.052))
        #expect(SceneChanges.text(from: before, to: Self.scene(after), since: 4) == "Unchanged since revision 4.")
    }

    @Test("panels redrawn around unchanged elements report the new panels and no element")
    func regroupedPanelsReportOnlyThePanels() {
        let before = Self.scene(Self.rows)
        let split = [SceneSection(name: "sidebar (Tracks)", bounds: Self.rect(0, 0, 0.3, 0.45)),
                     SceneSection(name: "region 1", bounds: Self.rect(0, 0.45, 0.3, 0.55))]
        let after = Self.scene(Self.rows.map { row in
            var row = row
            row.section = row.bounds.y < 0.45 ? "sidebar (Tracks)" : "region 1"
            return row
        }, sections: split)
        let changes = SceneChanges.text(from: before, to: after, since: 2)
        #expect(changes.hasPrefix("## sidebar (Tracks) @0,0 30x45\n## region 1 @0,45 30x55"))
        #expect(!changes.contains("[control]"))
    }

    @Test("an element now in another section is reported while its old section is still there")
    func aMoveBetweenStandingSectionsIsReported() {
        let panels = [SceneSection(name: "sidebar", bounds: Self.rect(0, 0, 0.3, 1)),
                      SceneSection(name: "content", bounds: Self.rect(0.3, 0, 0.7, 1))]
        let before = Self.scene([Self.element("Inbox", 0.1, 0.2, section: "sidebar")], sections: panels)
        let after  = Self.scene([Self.element("Inbox", 0.1, 0.2, section: "content")], sections: panels)
        #expect(SceneChanges.text(from: before, to: after, since: 3).split(separator: "\n") == [
            "## content @30,0 70x100",
            "~ [control] Inbox @10,20  (was in sidebar)",
        ])

        let renamed = [SceneSection(name: "sidebar (Mail)", bounds: Self.rect(0, 0, 0.3, 1)), panels[1]]
        let moved = Self.scene([Self.element("Inbox", 0.1, 0.2, section: "sidebar (Mail)")], sections: renamed)
        let changes = SceneChanges.text(from: before, to: moved, since: 3)
        #expect(changes.contains("## sidebar (Mail) @0,0 30x100"))
        #expect(!changes.contains("Inbox"))
    }

    @Test("panel edges that jitter are no change, a resized panel is")
    func sectionJitterIsNoChange() {
        let panels = [SceneSection(name: "sidebar", bounds: Self.rect(0, 0, 0.3, 1)),
                      SceneSection(name: "content", bounds: Self.rect(0.3, 0, 0.7, 1))]
        let rows = Self.rows.map { var row = $0; row.section = "sidebar"; return row }
        let before = Self.scene(rows, sections: panels)
        let jittered = [SceneSection(name: "sidebar", bounds: Self.rect(0, 0.01, 0.31, 0.99)),
                        SceneSection(name: "content", bounds: Self.rect(0.31, 0, 0.69, 1))]
        #expect(SceneChanges.text(from: before, to: Self.scene(rows, sections: jittered), since: 8)
            == "Unchanged since revision 8.")

        var stated = rows
        stated[0].state = .on
        let lines = SceneChanges.text(from: before, to: Self.scene(stated, sections: jittered), since: 8)
            .split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("## ") } == ["## sidebar @0,1 31x99"])

        let resized = [SceneSection(name: "sidebar", bounds: Self.rect(0, 0, 0.4, 1)),
                       SceneSection(name: "content", bounds: Self.rect(0.4, 0, 0.6, 1))]
        let changes = SceneChanges.text(from: before, to: Self.scene(rows, sections: resized), since: 8)
        #expect(changes.contains("## sidebar @0,0 40x100"))
        #expect(changes.contains("## content @40,0 60x100"))
        #expect(!changes.contains("[control]"))
    }

    @Test("a state, a value and a real move are reported on the element's current line with what it was")
    func changedElementsCarryTheirEarlierValues() {
        let before = Self.scene([
            Self.element("Mute", 0.1, 0.1, state: .off),
            Self.element("Gain", 0.1, 0.2, value: "-6 dB"),
            Self.element("Solo", 0.1, 0.3),
            Self.element("Pan", 0.1, 0.4),
        ])
        let after = Self.scene([
            Self.element("Mute", 0.1, 0.1, state: .on),
            Self.element("Gain", 0.1, 0.2, value: "0 dB"),
            Self.element("Solo", 0.5, 0.3),
            Self.element("Pan", 0.1, 0.4),
        ])
        let lines = SceneChanges.text(from: before, to: after, since: 7).split(separator: "\n").map(String.init)
        #expect(lines == [
            "## content @0,0 100x100",
            "~ [control] Mute [on] @10,10  (was [off])",
            "~ [control] Gain = 0 dB @10,20  (was = \"-6 dB\")",
            "~ [control] Solo @50,30  (was @10,30)",
        ])
    }

    @Test("an added element comes whole under its section, a removed one short")
    func addedAndRemovedElements() {
        let before = Self.scene(Self.rows)
        let after = Self.scene(Array(Self.rows.dropFirst()) + [Self.element("Track 7", 0.1, 0.7, value: "Bus A")])
        let changes = SceneChanges.text(from: before, to: after, since: 1)
        #expect(changes.hasPrefix("## content @0,0 100x100\n"))
        #expect(changes.contains("\n- [control] Track 1 @10,10"))
        #expect(changes.contains("\n+ [control] Track 7 = Bus A @10,70"))
        #expect(!changes.contains("Track 2"))
    }

    @Test("duplicates pair with the nearest; an unlabeled icon is matched by place and reported when it moves cell")
    func duplicatesAndUnlabeledIcons() {
        let before = Self.scene([
            Self.element("Reply", 0.5, 0.2), Self.element("Reply", 0.5, 0.6), Self.icon(0.30, 0.30),
        ])
        let after  = Self.scene([Self.element("Reply", 0.5, 0.6), Self.icon(0.36, 0.30)])
        let changes = SceneChanges.text(from: before, to: after, since: 3)
        #expect(changes.contains("\n- [control] Reply @50,20"))
        #expect(!changes.contains("@50,60"))
        #expect(changes.contains("\n- [icon?] id:'?|@3,3' @30,30"))
        #expect(changes.contains("\n+ [icon?] id:'?|@4,3' @36,30"))
    }

    @Test("a caption grouping fused into a control in place is one element whose tag changed")
    func aRegroupedCaptionIsTheSameElement() {
        let footer  = Self.element("Save", 0.50, 0.90, kind: .text)
        let before  = Self.scene([Self.element("Save", 0.50, 0.50, kind: .text), footer])
        let after   = Self.scene([Self.element("Save", 0.49, 0.50), footer])
        let changes = SceneChanges.text(from: before, to: after, since: 6)
        #expect(changes.split(separator: "\n").dropFirst() == ["~ [control] Save @49,50  (was [text])"])
    }

    @Test("a cell an unlabeled icon is targeted by is reported when jitter alone carries it across")
    func aChangedTargetIDIsReported() {
        let before = Self.scene([Self.icon(0.349, 0.30)])
        let after  = Self.scene([Self.icon(0.351, 0.30)])
        let changes = SceneChanges.text(from: before, to: after, since: 3)
        #expect(changes.contains("~ [icon?] id:'?|@4,3' @35,30  (was id:'?|@3,3')"))
    }

    @Test("the title, the viewport and the commands are reported when they change")
    func headerChanges() {
        let before = Self.scene(Self.rows, commands: ["File > Save"])
        let after  = Self.scene(Self.rows, title: "Mix 2", width: 1200, commands: ["File > Save", "File > Export"])
        let lines  = SceneChanges.text(from: before, to: after, since: 5).split(separator: "\n").map(String.init)
        #expect(lines == [
            "window: Mixer (com.example.mixer) \"Mix 2\"",
            "viewport: 1200x800",
            "commands (2): File > Save · File > Export",
        ])
    }

    @Test("a scene with no sections lists its changes without a heading")
    func flatScenes() {
        let before = Self.scene(Self.rows.map { var row = $0; row.section = nil; return row }, sections: [])
        var after = before
        after.elements[2].state = .on
        let changes = SceneChanges.text(from: before, to: after, since: 9)
        #expect(changes.split(separator: "\n") == ["~ [control] Track 3 [on] @10,30  (was no state)"])
    }
}

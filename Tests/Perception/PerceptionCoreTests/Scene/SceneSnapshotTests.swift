//
//  SceneSnapshotTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation
@testable import PerceptionCore
import Testing

/// The scene is the image-free boundary, so the tests read its JSON the way a stranger would: for
/// what it must never contain, for what it must always contain, and for a token that never moves
/// unless the screen does.
@Suite("Scene snapshot")
struct SceneSnapshotTests {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    private func sample() -> SceneSnapshot {
        SceneSnapshot(
            bundleID: "com.adobe.PremierePro", appName: "Adobe Premiere", windowTitle: "Untitled.prproj",
            viewportPixelSize: ViewportPixelSize(width: 1920, height: 1080),
            elements: [
                SceneElement(id: "text|export", kind: .text, label: "Export", bounds: rect(0.83, 0.06, 0.05, 0.02)),
                SceneElement(id: "icon|settings", kind: .icon, label: "settings", bounds: rect(0.12, 0.20, 0.02, 0.02)),
                SceneElement(id: "?|@3,4", kind: .icon, label: "(unlabeled)", bounds: rect(0.30, 0.40, 0.02, 0.02), isUnlabeled: true),
                SceneElement(id: "control|mute", kind: .control, label: "mute", bounds: rect(0.9, 0.5, 0.02, 0.02),
                             role: "AXCheckBox", state: .off),
            ],
            commands: ["File > Export…", "Edit > Undo"]
        )
    }

    @Test("the JSON carries no image or internal field")
    func imageFreeContract() throws {
        let json = String(decoding: try JSONEncoder().encode(sample()), as: UTF8.self).lowercased()
        for forbidden in ["cropref", "edgehash", "axpath", "\"path\"", "base64", "png", "pixel"] {
            #expect(!json.contains(forbidden), "scene JSON must not expose \(forbidden)")
        }
        #expect(json.contains("label"))
        #expect(json.contains("export"))
        #expect(json.contains("\"pos\""))
        #expect(json.contains("\"viewportpx\""))
    }

    @Test("round trip and text rendering")
    func roundTripAndText() throws {
        let scene = sample()
        let back = try JSONDecoder().decode(SceneSnapshot.self, from: JSONEncoder().encode(scene))
        #expect(back == scene)
        #expect(scene.text() == """
            Adobe Premiere (com.adobe.PremierePro) "Untitled.prproj" 1920x1080, 4 elements
            Export @83,6
            [icon] settings @12,20
            [control] mute [off] @90,50
            icons: ?|@3,4@30,40
            commands (2): File > Export… · Edit > Undo

            """)
    }

    @Test("a scene written by the previous engine still decodes")
    func legacyWireFormat() throws {
        let legacy = """
        {"bundleID":"com.x","app":"X","windowTitle":"W","viewportPx":[100,50],"commands":[],"token":"abc",
         "sections":[{"name":"top bar","pos":[0,0,1,0.1],"scrolls":"scrolls ↓ · learned"}],
         "elements":[{"id":"?|export","kind":"text","label":"Export","pos":[0.1,0.2,0.05,0.02]},
                     {"id":"?|@3,4","kind":"icon","label":"(unlabeled)","pos":[0.3,0.4,0.02,0.02],"unlabeled":true,"state":"off"}]}
        """
        let scene = try JSONDecoder().decode(SceneSnapshot.self, from: Data(legacy.utf8))
        #expect(scene.viewportPixelSize == ViewportPixelSize(width: 100, height: 50))
        #expect(scene.sections.first?.verticalScrollNote == "scrolls ↓ · learned")
        #expect(scene.elements[1].isUnlabeled)
        #expect(scene.elements[1].state == .off)
        #expect(scene.elements[0].isUnlabeled == false)
        #expect(scene.token.rawValue == "abc")
    }

    @Test("unnamed visual targets expose their IDs and retain media uncertainty in text")
    func unnamedTargetsKeepIdentityAndKind() {
        var scene = sample()
        scene.elements.append(SceneElement(
            id: "?|@7,6", kind: .overlayCandidate, label: "(unlabeled)",
            bounds: rect(0.7, 0.6, 0.02, 0.02), isUnlabeled: true
        ))
        let text = scene.text()
        #expect(text.contains("icons: ?|@3,4@30,40\n"))
        #expect(text.contains("[overlay-candidate?] id:'?|@7,6' @70,60\n"))
    }

    @Test("the token moves with content and state, and with nothing else")
    func tokenStability() {
        let a = sample()
        var b = sample()
        #expect(a.token == b.token)
        b.elements[3].state = .on
        let flipped = SceneSnapshot(bundleID: b.bundleID, appName: b.appName, windowTitle: b.windowTitle,
                                    viewportPixelSize: b.viewportPixelSize, elements: b.elements, commands: b.commands)
        #expect(flipped.token != a.token)
        let reordered = SceneSnapshot(bundleID: a.bundleID, appName: a.appName, windowTitle: a.windowTitle,
                                      viewportPixelSize: a.viewportPixelSize, elements: a.elements.reversed(), commands: [])
        #expect(reordered.token == a.token)
    }

    @Test("native text fields are distinguishable from a same-value visual control in both scene tiers")
    func fieldsHaveVisibleReferences() {
        let field = SceneElement(id: "native-name", kind: .control, label: "26.3",
                                 bounds: rect(0.23, 0.11, 0.5, 0.04), role: "AXTextField",
                                 value: "26.3", section: "content")
        let version = SceneElement(id: "version-row", kind: .control, label: "26.3",
                                   bounds: rect(0.27, 0.4, 0.1, 0.04), section: "content")
        let scene = SceneSnapshot(bundleID: "test", appName: "Test", windowTitle: "New Instance",
                                  viewportPixelSize: .init(width: 730, height: 586),
                                  elements: [version, field],
                                  sections: [SceneSection(name: "content", bounds: rect(0, 0, 1, 1))])
        for rendering in [scene.text(), scene.mapText()] {
            #expect(rendering.contains("[field] 26.3 id:'native-name'"))
            #expect(!rendering.contains("[field] 26.3 id:'version-row'"))
        }
        #expect(scene.resolve(target: "26.3") == .ambiguous(2))
        #expect(scene.resolve(target: "native-name") == .found(field))
    }

    @Test("identity keys are position-free when labeled and coarse when not")
    func identityKeys() {
        #expect(SceneIdentity.key(kind: .control, label: "Audio 6", bounds: rect(0.1, 0.2, 0.1, 0.1), isUnlabeled: false) == "control|audio6")
        #expect(SceneIdentity.key(kind: .control, label: "Audio 7", bounds: rect(0.9, 0.9, 0.1, 0.1), isUnlabeled: false) == "control|audio7")
        #expect(SceneIdentity.key(kind: .icon, label: "", bounds: rect(0.31, 0.44, 0.02, 0.02), isUnlabeled: true) == "?|@3,4")
    }

    @Test("one screen renders one text: panels and their elements in reading order, an open menu as listed")
    func textIsInReadingOrder() {
        let sections = [
            SceneSection(name: "content", bounds: rect(0.3, 0.1, 0.7, 0.9)),
            SceneSection(name: "top bar", bounds: rect(0, 0, 1, 0.1)),
            SceneSection(name: "sidebar", bounds: rect(0, 0.1, 0.3, 0.9)),
            SceneSection(name: "open menu", bounds: rect(0.5, 0.5, 0.2, 0.3)),
        ]
        func text(_ label: String, _ x: Double, _ y: Double, in section: String?) -> SceneElement {
            SceneElement(id: "text|\(label)", kind: .text, label: label, bounds: rect(x, y, 0.1, 0.02),
                         section: section)
        }
        // A label's box sits a few pixels below the icon beside it, and still shares its row.
        let elements = [
            text("Beta", 0.40, 0.204, in: "content"),
            SceneElement(id: "icon|alpha", kind: .icon, label: "Alpha", bounds: rect(0.32, 0.200, 0.02, 0.03),
                         section: "content"),
            text("Gamma", 0.32, 0.300, in: "content"),
            text("Title", 0.40, 0.020, in: "top bar"),
            text("Inbox", 0.02, 0.200, in: "sidebar"),
            text("Zoom", 0.52, 0.600, in: "open menu"),
            text("Yank", 0.52, 0.550, in: "open menu"),
            text("Loose", 0.90, 0.950, in: nil),
        ]
        let scene = SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "W",
                                  viewportPixelSize: ViewportPixelSize(width: 1000, height: 1000),
                                  elements: elements, sections: sections)
        // Everything but the menu's rows arrives in the opposite order.
        let menu = elements.filter { $0.section == "open menu" }
        let shuffled = SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "W",
                                     viewportPixelSize: ViewportPixelSize(width: 1000, height: 1000),
                                     elements: elements.filter { $0.section != "open menu" }.reversed() + menu,
                                     sections: sections.reversed())
        let order = scene.text().split(separator: "\n").dropFirst().map { line -> String in
            if line.hasPrefix("## ") { return String(line.dropFirst(3).components(separatedBy: " @")[0]) }
            let named = line.hasPrefix("[icon] ") ? line.dropFirst(7) : line[...]
            return String(named.components(separatedBy: " @")[0])
        }
        #expect(order == ["top bar", "Title", "sidebar", "Inbox", "content", "Alpha", "Beta", "Gamma",
                          "open menu", "Zoom", "Yank", "unsectioned", "Loose"])
        #expect(shuffled.text() == scene.text())
    }
}

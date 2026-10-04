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
        let text = scene.text()
        #expect(text.contains("Adobe Premiere (com.adobe.PremierePro)"))
        #expect(text.contains("[text] Export"))
        #expect(text.contains("[icon?] (unlabeled)"))
        #expect(text.contains("[control] mute [off]"))
        #expect(text.contains("File > Export…"))
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
        #expect(text.contains("id:'?|@3,4'"))
        #expect(text.contains("[overlay-candidate?] (unlabeled)"))
        #expect(text.contains("id:'?|@7,6'"))
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
}

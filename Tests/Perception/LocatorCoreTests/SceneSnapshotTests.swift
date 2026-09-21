import XCTest
@testable import LocatorCore

final class SceneSnapshotTests: XCTestCase {
    private func sample() -> SceneSnapshot {
        SceneSnapshot(bundleID: "com.adobe.PremierePro", app: "Adobe Premiere", windowTitle: "Untitled.prproj",
                      viewportPx: [1920, 1080], elements: [
                        SceneElement(id: "?|export", kind: "text", label: "Export", pos: [0.83, 0.06, 0.05, 0.02]),
                        SceneElement(id: "?|settings", kind: "icon", label: "settings", pos: [0.12, 0.20, 0.02, 0.02]),
                        SceneElement(id: "?|@3,4", kind: "icon", label: "(unlabeled)", pos: [0.30, 0.40, 0.02, 0.02], unlabeled: true),
                        SceneElement(id: "AXCheckBox|mute", kind: "control", label: "mute", pos: [0.9, 0.5, 0.02, 0.02], role: "AXCheckBox", state: "off"),
                      ], commands: ["File > Export…", "Edit > Undo"])
    }

    /// The image-free contract: the serialized scene must contain NO crop / hash / AX-path / pixel field.
    func testSceneCarriesNoImageOrInternalFields() throws {
        let json = String(decoding: try DescriptorStore.makeEncoder().encode(sample()), as: UTF8.self).lowercased()
        for forbidden in ["cropref", "edgehash", "axpath", "\"path\"", "base64", "png", "pixel"] {
            XCTAssertFalse(json.contains(forbidden), "scene JSON must not expose \(forbidden)")
        }
        // It DOES carry the LLM-facing fields.
        XCTAssertTrue(json.contains("label"))
        XCTAssertTrue(json.contains("export"))
    }

    func testRoundTripAndTextRendering() throws {
        let s = sample()
        let back = try DescriptorStore.makeDecoder().decode(SceneSnapshot.self, from: DescriptorStore.makeEncoder().encode(s))
        XCTAssertEqual(back, s)
        let text = s.text()
        XCTAssertTrue(text.contains("Adobe Premiere (com.adobe.PremierePro)"))
        XCTAssertTrue(text.contains("[text] Export"))
        XCTAssertTrue(text.contains("[icon?] (unlabeled)"))   // unlabeled surfaced honestly
        XCTAssertTrue(text.contains("[control] mute [off]"))
        XCTAssertTrue(text.contains("File > Export…"))
    }
}

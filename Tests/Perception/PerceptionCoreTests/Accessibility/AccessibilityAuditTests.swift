import CoreGraphics
import Foundation
import PerceptionCore
import Testing

@Suite("Accessibility audit regressions")
struct AccessibilityAuditTests {
    @Test("a native multiline editor upgrades its matching pixel caption and remains a text target")
    func textAreaKeepsItsNativeRole() {
        let bounds = NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4)
        let caption = SceneElement(id: "pixel-body", kind: .text, label: "Body", bounds: bounds)
        let editor = SceneElement(id: "native-body", kind: .control, label: "Body", bounds: bounds,
                                  role: "AXTextArea", value: "Seed")
        let merged = AccessibilityAugmentation.merge(pixels: [caption], accessibility: [editor])
        #expect(merged == [editor])
        let scene = SceneSnapshot(bundleID: "test", appName: "Test", windowTitle: "Editor",
                                  viewportPixelSize: .init(width: 800, height: 600), elements: merged)
        #expect(scene.resolve(target: "native-body") == .found(editor))
    }
    @Test("a renamed OCR value still merges a later native facet by its new name")
    func renamedValueKeysStayCurrent() {
        let rect = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        let pixel = SceneElement(id: "stereo", kind: .text, label: "Stereo", bounds: rect)
        let first = SceneElement(id: "format", kind: .control, label: "Format", bounds: rect,
                                 role: "AXPopUpButton", value: "Stereo", isEnabled: true)
        let second = SceneElement(id: "format-again", kind: .control, label: "Format #2", bounds: rect,
                                  role: "AXComboBox", value: "Stereo", isEnabled: false)
        let merged = AccessibilityAugmentation.merge(pixels: [pixel], accessibility: [first, second])
        #expect(merged.count == 1)
        #expect(merged.first?.label == "Format")
        #expect(merged.first?.role == "AXPopUpButton")
        #expect(merged.first?.isEnabled == true)
    }

    @Test("a field's value merges only with its own pixel label and stays targetable")
    func mergeFieldValue() {
        let bounds = NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.03)
        let pixels = [SceneElement(id: "text|stereo", kind: .text, label: "Stereo", bounds: bounds)]
        let field = SceneElement(id: "control|format", kind: .control, label: "Format", bounds: bounds,
                                 role: "AXPopUpButton", value: "Stereo")
        let result = AccessibilityAugmentation.merge(pixels: pixels, accessibility: [field])
        #expect(result.count == 1)
        #expect(result.first?.label == "Format")
        #expect(result.first?.value == "Stereo")
        let scene = SceneSnapshot(bundleID: "test", appName: "Test", windowTitle: "Window",
                                  viewportPixelSize: .init(width: 800, height: 600), elements: result)
        guard case .found(let resolved) = scene.resolve(target: "Stereo") else {
            Issue.record("the current dropdown value must remain a usable target")
            return
        }
        #expect(resolved.label == "Format")
    }

    @Test("partially clipped accessibility bounds remain inside the captured image")
    func clippedBounds() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(AccessibilityFrameTrust.normalized(CGRect(x: -10, y: 10, width: 20, height: 20), in: window)
            == NormalizedRect(x: 0, y: 0.1, width: 0.1, height: 0.2))
    }
    @Test("table controls keep their column label, value and row owner")
    func tableControls() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let row = FakeNode("AXRow", frame: CGRect(x: 10, y: 50, width: 400, height: 24)).adding(
            FakeNode("AXCell").adding(FakeNode("AXTextField", title: "Bus 1-2", value: "Bus 1-2",
                frame: CGRect(x: 10, y: 50, width: 200, height: 24))),
            FakeNode("AXCell").adding(FakeNode("AXMenuButton", title: "Stereo", value: "Stereo",
                frame: CGRect(x: 220, y: 50, width: 80, height: 24))),
            FakeNode("AXCell").adding(FakeNode("AXCheckBox", numericValue: 1,
                frame: CGRect(x: 320, y: 50, width: 20, height: 24))))
        let table = FakeNode("AXTable", title: "Bus Setup", frame: frame).adding(row,
            FakeNode("AXColumn", title: "Name"), FakeNode("AXColumn", title: "Format"),
            FakeNode("AXColumn", title: "Mapping to Output"))
        let root = FakeNode("AXWindow", frame: frame).adding(table)
        let elements = AccessibilityAugmentation.elements(under: root, windowFrame: frame, reader: FakeReader())
        let format = elements.first { $0.label == "Format" }
        #expect(format?.value == "Stereo")
        #expect(format?.container == "Bus Setup / Bus 1-2")
        #expect(elements.first { $0.label == "Mapping to Output" }?.state == .on)
    }
    @Test("availability, value and owner round-trip and invalidate the scene token")
    func liveFacts() throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let root = FakeNode("AXWindow", frame: frame).adding(
            FakeNode("AXButton", title: "Delete Path", frame: CGRect(x: 20, y: 20, width: 120, height: 24),
                     isEnabled: false))
        let result = AccessibilityAugmentation.elements(under: root, windowFrame: frame, reader: FakeReader())
        let disabled = try #require(result.first)
        #expect(disabled.isEnabled == false)
        var changed = disabled
        changed.isEnabled = true
        let originalToken = SceneToken(bundleID: "test", windowTitle: "Window", elements: [disabled])
        #expect(originalToken != SceneToken(bundleID: "test", windowTitle: "Window", elements: [changed]))
        changed = disabled
        changed.value = "Stereo"
        changed.container = "Track 1"
        #expect(try JSONDecoder().decode(SceneElement.self, from: JSONEncoder().encode(changed)) == changed)
        #expect(originalToken != SceneToken(bundleID: "test", windowTitle: "Window", elements: [changed]))
    }
    @Test("track ownership survives harvest and resolves repeated controls")
    func trackContext() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let root = FakeNode("AXWindow", frame: frame)
        for (i, title) in ["Guitar 1 - Audio Track ", "Guitar 2 - Audio Track "].enumerated() {
            root.adding(FakeNode("AXGroup", title: title, frame: CGRect(x: 0, y: i * 80, width: 300, height: 70))
                .adding(FakeNode("AXButton", title: "Solo", frame: CGRect(x: 30, y: i * 80 + 20, width: 20, height: 20))))
        }
        let elements = AccessibilityAugmentation.elements(under: root, windowFrame: frame, reader: FakeReader())
        #expect(elements.map(\.label) == ["Solo", "Solo"])
        #expect(elements.map(\.container) == ["Guitar 1", "Guitar 2"])
        let scene = SceneSnapshot(bundleID: "test", appName: "Test", windowTitle: "Tracks",
                                  viewportPixelSize: .init(width: 800, height: 600), elements: elements)
        #expect(scene.resolve(target: "Solo") == .ambiguous(2))
        #expect(scene.resolve(target: "Solo", section: "Guitar 2") == .found(elements[1]))
    }

    @Test("field names and current values remain separate facts")
    func fieldValue() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let root = FakeNode("AXWindow", frame: frame).adding(
            FakeNode("AXPopUpButton", descriptionText: "Format", value: "Stereo",
                     frame: CGRect(x: 20, y: 20, width: 120, height: 24)))
        let result = AccessibilityAugmentation.elements(under: root, windowFrame: frame, reader: FakeReader())
        #expect(result.first?.label == "Format")
        #expect(result.first?.value == "Stereo")
        #expect(result.first?.isEnabled == true)
    }

    @Test("capture frame selects the background window and refuses stale or ambiguous trees")
    func windowMatching() {
        let main = FakeNode("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let dialog = FakeNode("AXWindow", frame: CGRect(x: 150, y: 150, width: 300, height: 150))
        let nodes = [dialog, main]
        #expect(AccessibilityWindowMatching.window(among: nodes, capturedFrame: main.frame ?? .zero,
                                                   reader: FakeReader()) === main)
        #expect(AccessibilityWindowMatching.window(among: nodes, capturedFrame: dialog.frame ?? .zero,
                                                   reader: FakeReader()) === dialog)
        #expect(AccessibilityWindowMatching.window(among: nodes, capturedFrame: CGRect(x: 2000, y: 0, width: 800, height: 600),
                                                   reader: FakeReader()) == nil)
        #expect(AccessibilityWindowMatching.window(among: [main, main], capturedFrame: main.frame ?? .zero,
                                                   reader: FakeReader()) == nil)
    }
    @Test("capture identity disambiguates equal frames without accepting absent or stale recipients")
    func overlappingWindowIdentity() {
        let frame = CGRect(x: 2000, y: 1000, width: 1200, height: 828)
        let captured = FakeNode("AXWindow", frame: frame)
        let other = FakeNode("AXWindow", frame: frame)
        let nodes = [other, captured]
        let reader = FakeReader()
        #expect(AccessibilityWindowMatching.window(
            among: nodes, capturedFrame: frame, reader: reader,
            isCapturedWindow: { $0 === captured }
        ) === captured)
        #expect(AccessibilityWindowMatching.window(
            among: [other], capturedFrame: frame, reader: reader,
            isCapturedWindow: { $0 === captured }
        ) == nil)
        #expect(AccessibilityWindowMatching.window(
            among: nodes, capturedFrame: frame.offsetBy(dx: 100, dy: 0), reader: reader,
            isCapturedWindow: { $0 === captured }
        ) == nil)
        #expect(AccessibilityWindowMatching.window(
            among: [captured, captured], capturedFrame: frame, reader: reader,
            isCapturedWindow: { $0 === captured }
        ) == nil)
    }

    @Test("neighboring repeated controls are never discarded as duplicate facets")
    func neighboringControls() {
        let bounds = [0.10, 0.135].map { NormalizedRect(x: $0, y: 0.2, width: 0.02, height: 0.03) }
        let controls = bounds.enumerated().map { index, rect in
            SceneElement(id: "control|mute", kind: .control, label: index == 0 ? "Mute" : "Mute #2",
                         bounds: rect, role: "AXButton")
        }
        let merged = AccessibilityAugmentation.merge(pixels: [], accessibility: controls)
        #expect(merged.count == 2)
        #expect(merged.map(\.bounds) == bounds)
    }

    @Test("matching selects the overlapping row rather than a nearby row with the same name")
    func matchingRow() {
        let first = SceneElement(id: "text|audio", kind: .text, label: "Audio",
                                bounds: NormalizedRect(x: 0.1, y: 0.20, width: 0.06, height: 0.01))
        var second = first
        second.bounds.y = 0.225
        let control = SceneElement(id: "control|audio", kind: .control, label: "Audio",
                                   bounds: NormalizedRect(x: 0.095, y: 0.223, width: 0.1, height: 0.014),
                                   role: "AXButton")
        let result = AccessibilityAugmentation.merge(pixels: [first, second], accessibility: [control])
        #expect(result[0].kind == .text)
        #expect(result[1].kind == .control)
    }

    @Test("a table cannot exceed the element budget or suppress later non-table controls")
    func tableBudgets() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let table = FakeNode("AXTable", frame: frame)
        for i in 0..<8 {
            table.adding(FakeNode("AXRow", value: "Row \(i)",
                                  frame: CGRect(x: 10, y: 20 + i * 24, width: 200, height: 20)))
        }
        let root = FakeNode("AXWindow", frame: frame).adding(table,
            FakeNode("AXButton", title: "Cancel", frame: CGRect(x: 600, y: 500, width: 80, height: 24)))
        let limited = AccessibilityAugmentation.elements(under: root, windowFrame: frame, reader: FakeReader(),
                                                        limits: .init(maxElements: 3))
        #expect(limited.count == 3)
        let oneTable = AccessibilityAugmentation.elements(under: root, windowFrame: frame, reader: FakeReader(),
                                                         limits: .init(maxTables: 1))
        #expect(oneTable.contains { $0.label == "Cancel" })
    }
}

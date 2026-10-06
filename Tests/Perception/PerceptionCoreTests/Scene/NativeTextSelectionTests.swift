import Foundation
import PerceptionCore
import Testing

@Suite("Native text selection")
struct NativeTextSelectionTests {

    private func field(value: String?, selection: NSRange?) -> SceneElement {
        SceneElement(
            id           : "control|editor",
            kind         : .control,
            label        : "Editor",
            bounds       : NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1),
            role         : "AXTextArea",
            value        : value,
            selectedRange: selection
        )
    }

    @Test("selection bounds use UTF-16, including a caret in known empty text")
    func selectionFitsExactText() {
        let unicode = "Aé🧪"
        for selection in [NSRange(location: 0, length: 4), NSRange(location: 4, length: 0)] {
            #expect(field(value: unicode, selection: selection).selectedRange == selection)
        }
        #expect(field(value: "", selection: NSRange(location: 0, length: 0)).selectedRange
            == NSRange(location: 0, length: 0))
    }

    @Test("missing values and invalid ranges cannot establish selection")
    func invalidSelectionIsUnavailable() {
        #expect(field(value: nil, selection: NSRange(location: 0, length: 0)).selectedRange == nil)
        for selection in [
            NSRange(location: -1, length: 0),
            NSRange(location: 0, length: -1),
            NSRange(location: 5, length: 0),
            NSRange(location: 3, length: 2),
            NSRange(location: 1, length: Int.max),
            NSRange(location: Int.max, length: 1),
        ] {
            #expect(field(value: "Aé🧪", selection: selection).selectedRange == nil)
        }
    }

    @Test("stored selection round-trips and older scenes retain unavailable selection")
    func selectionWireCompatibility() throws {
        let element = field(value: "  Aé🧪\r\n", selection: NSRange(location: 2, length: 4))
        let data = try JSONEncoder().encode(element)
        #expect(try JSONDecoder().decode(SceneElement.self, from: data) == element)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "selectedRange")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let oldElement = try JSONDecoder().decode(SceneElement.self, from: oldData)
        #expect(oldElement.value == element.value)
        #expect(oldElement.selectedRange == nil)
    }

    @Test("a stored range outside its decoded value is discarded")
    func staleStoredSelectionIsUnavailable() throws {
        let data = try JSONEncoder().encode(field(value: "Aé🧪", selection: NSRange(location: 0, length: 4)))
        var stored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        stored["value"] = "A"
        let changedData = try JSONSerialization.data(withJSONObject: stored)
        #expect(try JSONDecoder().decode(SceneElement.self, from: changedData).selectedRange == nil)
    }

    @Test("mutating the value cannot serialize an obsolete selection")
    func changedValueInvalidatesSerializedSelection() throws {
        var element = field(value: "Aé🧪", selection: NSRange(location: 0, length: 4))
        element.value = ""
        let data = try JSONEncoder().encode(element)
        #expect(try JSONDecoder().decode(SceneElement.self, from: data).selectedRange == nil)
    }

    @Test("a selection change invalidates an action's echoed scene token")
    func selectionChangesToken() {
        let caret = field(value: "Aé🧪", selection: NSRange(location: 4, length: 0))
        let selected = field(value: "Aé🧪", selection: NSRange(location: 0, length: 4))
        let unknown = field(value: "Aé🧪", selection: nil)
        let caretToken = SceneToken(bundleID: "fixture", windowTitle: "Editor", elements: [caret])
        let selectedToken = SceneToken(bundleID: "fixture", windowTitle: "Editor", elements: [selected])
        let unknownToken = SceneToken(bundleID: "fixture", windowTitle: "Editor", elements: [unknown])
        #expect(caretToken != selectedToken)
        #expect(selectedToken != unknownToken)
        #expect(caretToken != unknownToken)
    }
}

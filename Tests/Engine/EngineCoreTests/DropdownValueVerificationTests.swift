import EngineCore
import PerceptionCore
import Testing

@Suite("Dropdown effect verification")
struct DropdownValueVerificationTests {

    private let bounds = NormalizedRect(x: 0.2, y: 0.3, width: 0.15, height: 0.04)

    @Test("a native dropdown keeps its name while its observed value changes")
    func nativeValue() {
        let before = SceneElement(id: "choice", kind: .control, label: "Probe Choice", bounds: bounds,
                                  role: "AXPopUpButton", value: "Alpha")
        var after = before
        after.value = "Beta"
        #expect(DropdownValueVerification.verifies(item: "Beta", control: before, after: [after]))
        #expect(!DropdownValueVerification.verifies(item: "Alpha", control: before, after: [after]))
    }

    @Test("another control, an editor value and an unchanged dropdown cannot prove selection")
    func unrelatedValues() {
        let before = SceneElement(id: "choice", kind: .control, label: "Probe Choice", bounds: bounds,
                                  role: "AXPopUpButton", value: "Alpha")
        var other = before
        other.value = "Beta"
        other.bounds.y = 0.7
        var editor = before
        editor.role = "AXTextField"
        editor.value = "Beta"
        #expect(!DropdownValueVerification.verifies(item: "Beta", control: before, after: [before]))
        #expect(!DropdownValueVerification.verifies(item: "Beta", control: before, after: [other]))
        #expect(!DropdownValueVerification.verifies(item: "Beta", control: before, after: [editor]))
    }

    @Test("a visible pixel value at the control remains valid evidence")
    func pixelValue() {
        let before = SceneElement(id: "choice", kind: .control, label: "Alpha", bounds: bounds)
        let after = SceneElement(id: "new-value", kind: .text, label: "Beta", bounds: bounds)
        #expect(DropdownValueVerification.verifies(item: "Beta", control: before, after: [after]))
    }
}

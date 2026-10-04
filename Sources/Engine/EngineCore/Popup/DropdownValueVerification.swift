import CoreGraphics
import PerceptionCore

/// DropdownValueVerification checks the requested value at the original control's position.
/// A value elsewhere in the scene cannot establish the dropdown's selection.
public enum DropdownValueVerification {

    public static func verifies(
        item: String,
        control: SceneElement,
        after elements: [SceneElement]
    ) -> Bool {
        elements.contains { element in
            let nativeDropdown = ["AXPopUpButton", "AXComboBox"].contains(element.role ?? "")
            let value = nativeDropdown ? element.value ?? element.label : element.label
            let original = control.bounds.cgRect
            let current = element.bounds.cgRect
            let overlap = original.intersection(current)
            return LabelText.normalize(value) == LabelText.normalize(item)
                && !overlap.isNull && overlap.width > 0
                && overlap.height > min(original.height, current.height) * 0.5
        }
    }
}

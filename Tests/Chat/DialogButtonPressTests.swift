//
//  DialogButtonPressTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AutomationRuntime
import EngineCore
import Testing

/// The choice of one dialog button by its title, over the buttons of Photoshop's replace alert
/// as measured on 30/09/2026.
@MainActor
@Suite("Pressing a dialog button by its title")
struct DialogButtonPressTests {

    typealias Button = DialogButtonPress.Button<String>

    static let alert = [
        Button(title: "Cancel", isEnabled: true, element: "cancel"),
        Button(title: "Replace", isEnabled: true, element: "replace"),
    ]

    func kind(_ title: String, among buttons: [Button] = Self.alert, allowsDestructive: Bool = false) -> ActOutcomeKind? {
        guard case .outcome(let outcome) = DialogButtonPress.resolve(title, among: buttons,
                                                                     allowsDestructive: allowsDestructive)
        else { return nil }
        return outcome.kind
    }

    @Test("the one enabled button with the title is pressed, whatever its case")
    func theButtonIsPressed() {
        guard case .press(let element, let title) = DialogButtonPress.resolve("cancel", among: Self.alert,
                                                                               allowsDestructive: false)
        else { Issue.record("the button was not pressed"); return }
        #expect(element == "cancel")
        #expect(title == "Cancel")
    }

    @Test("a missing, doubled, disabled or destructive button is not pressed")
    func refusals() {
        #expect(kind("OK") == .honestMiss)
        #expect(kind("OK", among: Self.alert + [Button(title: "OK", isEnabled: true, element: "a"),
                                               Button(title: "OK", isEnabled: true, element: "b")]) == .ambiguous)
        #expect(kind("Save", among: [Button(title: "Save", isEnabled: false, element: "save")]) == .refused)
        #expect(kind("Delete", among: [Button(title: "Delete", isEnabled: true, element: "delete")]) == .refused)
        #expect(kind("Delete", among: [Button(title: "Delete", isEnabled: true, element: "delete")],
                     allowsDestructive: true) == nil)
    }
}

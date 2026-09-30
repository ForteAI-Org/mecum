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

    // MARK: The scope searched

    /// Photoshop's document behind its "Save changes?" alert, and a second dialog, by Window ID.
    static let windows: [Int: String] = [1: "document", 2: "alert", 3: "panel"]

    static let buttonsOf: [String: [Button]] = [
        "document": [Button(title: "Select and Mask...", isEnabled: true, element: "mask"),
                     Button(title: "OK", isEnabled: true, element: "document ok")],
        "alert"   : [Button(title: "Save", isEnabled: true, element: "save"),
                     Button(title: "OK", isEnabled: true, element: "alert ok")],
        "panel"   : [Button(title: "Cancel", isEnabled: true, element: "cancel"),
                     Button(title: "OK", isEnabled: true, element: "panel ok")],
    ]

    func scope(_ dialogs: [Int]) -> [String] {
        DialogButtonPress.scope(dialogs: dialogs, window: { Self.windows[$0] }, focusedWindow: { "document" })
    }

    func resolution(_ title: String, in dialogs: [Int]) -> DialogButtonPress.Resolution<String> {
        DialogButtonPress.resolve(title, among: scope(dialogs).flatMap { Self.buttonsOf[$0] ?? [] },
                                  allowsDestructive: false)
    }

    @Test("the dialogs the seat holds are the scope, and the focused window only when it holds none")
    func theScopeIsTheHeldDialogs() {
        #expect(scope([2, 3]) == ["alert", "panel"])
        #expect(scope([2]) == ["alert"], "a document still focused behind the alert is not searched")
        #expect(scope([]) == ["document"])
        #expect(scope([9]).isEmpty, "a held dialog accessibility cannot find is not replaced by the focus")
    }

    @Test("a button of one held dialog is pressed across the scope, and a title in two is ambiguous")
    func theButtonIsChosenAcrossTheScope() {
        guard case .press(let element, _) = resolution("Save", in: [2, 3]) else {
            Issue.record("Save was not pressed"); return
        }
        #expect(element == "save")
        guard case .outcome(let ambiguous) = resolution("OK", in: [2, 3]) else {
            Issue.record("OK in two dialogs was pressed"); return
        }
        #expect(ambiguous.kind == .ambiguous)
        guard case .outcome(let missing) = resolution("Select and Mask...", in: [2, 3]) else {
            Issue.record("a button of the document was pressed"); return
        }
        #expect(missing.kind == .honestMiss)
        #expect(missing.message.hasSuffix("Its buttons: Save, OK, Cancel, OK."), "the listing is the scope's")
    }
}

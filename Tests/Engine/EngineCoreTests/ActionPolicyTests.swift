//
//  ActionPolicyTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

@testable import EngineCore
import Testing

@Suite("Action policy")
struct ActionPolicyTests {

    @Test("destructive labels are caught in English and Italian, safe ones pass")
    func destructive() {
        for label in ["Delete", "Empty Trash", "Send", "Quit Premiere", "Elimina", "Invia messaggio", "Esci", "Svuota"] {
            #expect(ActionPolicy.isDestructive(label: label), Comment(rawValue: label))
        }
        for label in ["Export", "Save", "Mute Track", "Audio 4", "48000", "OK"] {
            #expect(!ActionPolicy.isDestructive(label: label), Comment(rawValue: label))
        }
        #expect(!ActionPolicy.isDestructive(label: nil))
    }

    @Test func menuCategoriesAndDestructiveSubmenusAreDistinct() {
        #expect(!ActionPolicy.isDestructive(menuPath: ["Format", "Font", "Show Fonts"]))
        #expect(ActionPolicy.isDestructive(menuPath: ["File", "Format Disk"]))
        #expect(ActionPolicy.isDestructive(menuPath: ["Layer", "Delete", "Layer"]))
    }

    @Test("activation is skipped in front or while a pop-up is open")
    func activation() {
        #expect(ActivationPolicy.needsActivation(target: 5, frontmost: 7, isPopupOpen: false))
        #expect(!ActivationPolicy.needsActivation(target: 5, frontmost: 5, isPopupOpen: false))
        #expect(!ActivationPolicy.needsActivation(target: 5, frontmost: 7, isPopupOpen: true))
        #expect(ActivationPolicy.needsActivation(target: 5, frontmost: nil, isPopupOpen: false))
    }

    @Test("verbs keep the tool vocabulary")
    func verbs() {
        #expect(ActionVerb(rawValue: "double_click") == .doubleClick)
        #expect(ActionVerb.setToggle.rawValue == "set_toggle")
        #expect(ActionVerb.click.performed == "clicked")
    }
}

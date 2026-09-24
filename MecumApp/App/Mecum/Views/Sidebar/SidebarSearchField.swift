//
//  SidebarSearchField.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import SwiftUI

/// SidebarSearchField is the system's search field at the top of the team's
/// sidebar, finding a worker by name or role as the person types. Its clear
/// button and Escape empty it. It draws no focus ring; the caret says it has
/// the keyboard.
struct SidebarSearchField: NSViewRepresentable {

    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString            = "Search"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString       = false
        field.delegate                     = context.coordinator
        field.focusRingType                = .none
        field.setAccessibilityLabel("Search workers")
        return field
    }

    func updateNSView(
        _ field: NSSearchField,
        context: Context
    ) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {

        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }

            text.wrappedValue = field.stringValue
        }
    }
}

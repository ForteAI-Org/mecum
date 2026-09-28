//
//  ComposerField.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// ComposerField hosts `ComposerTextView` in SwiftUI, with the draft as a binding.
///
/// The binding receives committed text only. While an input method composes,
/// the field shows the marked text and the binding keeps what was there
/// before it, so a draft written meanwhile never holds a half-composed
/// character; the composition reaches it once committed.
///
/// A binding that moves away from what the field last gave it was changed from
/// outside (a send cleared it, a refusal restored it, another conversation
/// opened), and the field takes that text, dropping any composition.
struct ComposerField: NSViewRepresentable {

    @Binding var text: String

    /// "Message Milo": the placeholder and the VoiceOver label (§13.1, §3.3).
    let placeholder: String

    /// What Return does. Nil while nothing can be sent.
    let onSubmit: (() -> Void)?

    /// Whether Return sends, or starts a new line with Command-Return sending.
    var returnSends = true

    /// What Escape does, nil to leave it to the text view.
    var onEscape: (() -> Void)?

    /// A count that puts the keyboard in the field each time it moves, as a reply
    /// started from the transcript asks, so the reply can be typed at once.
    var focusRequest = 0

    func makeNSView(context: Context) -> ComposerScrollView {
        let view = ComposerScrollView()
        view.textView.delegate = context.coordinator
        view.textView.string   = text
        context.coordinator.agreed       = text
        context.coordinator.focusRequest = focusRequest
        return view
    }

    func updateNSView(_ view: ComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        let textView    = view.textView
        coordinator.field    = self
        textView.placeholder = placeholder
        textView.onSubmit    = onSubmit
        textView.onEscape    = onEscape
        textView.returnSends = returnSends
        textView.setAccessibilityLabel(placeholder)

        if focusRequest != coordinator.focusRequest {
            coordinator.focusRequest = focusRequest
            // After this update, so the change of first responder does not land inside it.
            Task { @MainActor [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }

        guard text != coordinator.agreed else { return }
        textView.replaceText(with: text)
        coordinator.agreed = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    /// Coordinator carries typed text into the binding. Main actor: it is the
    /// text view's delegate and runs where the text view does.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var field: ComposerField

        /// The text the field and the binding last agreed on.
        var agreed = ""

        /// The focus request the field last acted on.
        var focusRequest = 0

        init(field: ComposerField) { self.field = field }

        func textDidChange(_ notification: Notification) {
            // A composition is not text yet. `setMarkedText` posts no notice on macOS 27, so this covers
            // one that arrives mid-composition anyway; the draft gets the text once it is committed.
            guard let textView = notification.object as? NSTextView, !textView.hasMarkedText() else { return }
            agreed     = textView.string
            field.text = agreed
        }
    }
}

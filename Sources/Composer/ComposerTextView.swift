//
//  ComposerTextView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// ComposerTextView is the composer's editing surface (§13.2): Return sends,
/// Option-Return inserts a line break.
///
/// A send is only ever the `insertNewline(_:)` command, which the key bindings
/// raise for a Return that no input method consumed. While marked text is
/// pending that command commits the composition instead, so a Return that
/// confirms a conversion never sends. Text from an input method or dictation
/// arrives through `insertText`, which never sends, even with a line break in it.
///
/// Main actor, like every view. It owns no draft: `ComposerField` reads it.
final class ComposerTextView: NSTextView {

    /// Called for a Return that should send. Nil while nothing can be sent, and
    /// a Return then does nothing.
    var onSubmit: (() -> Void)?

    /// Drawn while the field is empty and nothing is being composed.
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    private var isShowingPlaceholder = false

    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() {
            // Return confirms the composition, as the input method's own Return does, and sends nothing.
            unmarkText()
            didChangeText()
            return
        }
        onSubmit?()
    }

    // Tab leaves the field, so the keyboard reaches Send and Stop after it (§3.3).
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }

    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    override func didChangeText() {
        super.didChangeText()
        textDidChangeShape()
    }

    // Marked text reaches the storage without `didChangeText`, and can still add a line or hide the placeholder.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        textDidChangeShape()
    }

    /// Replaces the whole text from outside the keyboard: a send cleared it, a
    /// refusal put it back, or another conversation opened. A pending
    /// composition is dropped, and so is the undo history of the old text.
    func replaceText(with text: String) {
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        string = text
        undoManager?.removeAllActions(withTarget: self)
        if let textStorage { undoManager?.removeAllActions(withTarget: textStorage) }
        needsDisplay = true
        textDidChangeShape()
    }

    /// Redraws when the placeholder appears or goes, and asks the enclosing
    /// field for a new height when the lines changed.
    private func textDidChangeShape() {
        if (isEmpty && !placeholder.isEmpty) != isShowingPlaceholder { needsDisplay = true }
        (enclosingScrollView as? ComposerScrollView)?.updateHeight()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        isShowingPlaceholder = isEmpty && !placeholder.isEmpty
        guard isShowingPlaceholder else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font           : font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    private var isEmpty: Bool { (textStorage?.length ?? 0) == 0 && !hasMarkedText() }
}

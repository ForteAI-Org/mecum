//
//  ComposerTextView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// ComposerTextView is the composer's editing surface (§13.2): Return sends,
/// Shift-Return and Option-Return insert a line break that keeps the current
/// line's indentation, and Tab and Shift-Tab indent and outdent, so code can
/// be written in it. Control-Tab and Control-Shift-Tab move the focus, which
/// is the macOS convention for a text view (§3.3).
///
/// A send is only ever the `insertNewline(_:)` command, which the key bindings
/// raise for a Return that no input method consumed. While marked text is
/// pending that command commits the composition instead, so a Return that
/// confirms a conversion never sends. Text from an input method or dictation
/// arrives through `insertText`, which never sends, even with a line break in it.
///
/// Main actor, like every view. It owns no draft: `ComposerField` reads it.
final class ComposerTextView: NSTextView {

    /// One level of indentation, as Tab inserts it and Shift-Tab removes it.
    static let indentation = "    "

    /// Called for a Return that should send. Nil while nothing can be sent, and
    /// a Return then does nothing.
    var onSubmit: (() -> Void)?

    /// Whether Return sends. When it does not, Return starts a new line and
    /// Command-Return sends, through the send button's shortcut.
    var returnSends = true

    /// Drawn while the field is empty and nothing is being composed.
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    private var isShowingPlaceholder = false

    /// The key down being interpreted, so a command can tell which modifiers
    /// raised it. Set only for the duration of `keyDown(with:)`.
    private var interpretedKey: NSEvent?

    override func keyDown(with event: NSEvent) {
        interpretedKey = event
        defer { interpretedKey = nil }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() {
            // Return confirms the composition, as the input method's own Return does, and sends nothing.
            unmarkText()
            didChangeText()
            return
        }
        // Shift-Return reaches this command like Return does; only its modifier tells them apart.
        if isInterpreting(.shift) || !returnSends {
            insertLineBreak()
            return
        }
        onSubmit?()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertLineBreak() }

    override func insertTab(_ sender: Any?) {
        if isInterpreting(.control) {
            window?.selectNextKeyView(sender)
        } else if spansLines(selectedRange()) {
            rewriteSelectedLines { Self.indentation + $0 }
        } else {
            insertText(Self.indentation, replacementRange: selectedRange())
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if isInterpreting(.control) {
            window?.selectPreviousKeyView(sender)
            return
        }
        rewriteSelectedLines { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, Self.indentation.count)))
        }
    }

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

    private func isInterpreting(_ modifier: NSEvent.ModifierFlags) -> Bool {
        interpretedKey?.modifierFlags.contains(modifier) ?? false
    }

    /// Breaks the line at the caret and repeats the indentation before it. A
    /// composition in progress is committed first, so none of it is lost.
    private func insertLineBreak() {
        if hasMarkedText() { unmarkText() }
        let text      = string as NSString
        let selection = selectedRange()
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before    = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let indent    = before.prefix { $0 == " " || $0 == "\t" }
        insertText("\n" + indent, replacementRange: selection)
    }

    /// A selection that holds a line break, so Tab indents its lines instead of replacing it.
    private func spansLines(_ selection: NSRange) -> Bool {
        selection.length > 0 && (string as NSString).substring(with: selection).contains("\n")
    }

    /// Rewrites each line the selection touches, as one undoable change. An
    /// empty selection keeps the caret where it was on its line; any other
    /// selects the rewritten lines.
    private func rewriteSelectedLines(_ rewrite: (Substring) -> String) {
        let text      = string as NSString
        let selection = selectedRange()
        // A selection ending just after a line break does not touch the line below it.
        let touched   = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let lines     = text.lineRange(for: touched)
        let old       = text.substring(with: lines)
        let hasBreak  = old.hasSuffix("\n")
        let body      = hasBreak ? old.dropLast() : Substring(old)
        let new       = body.split(separator: "\n", omittingEmptySubsequences: false).map(rewrite)
            .joined(separator: "\n") + (hasBreak ? "\n" : "")
        guard new != old, shouldChangeText(in: lines, replacementString: new) else { return }
        replaceCharacters(in: lines, with: new)
        didChangeText()
        let newLength = (new as NSString).length
        if selection.length == 0 {
            let moved = selection.location + newLength - lines.length
            setSelectedRange(NSRange(location: max(lines.location, moved), length: 0))
        } else {
            setSelectedRange(NSRange(location: lines.location, length: newLength - (hasBreak ? 1 : 0)))
        }
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

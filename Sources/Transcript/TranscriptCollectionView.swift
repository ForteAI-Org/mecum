//
//  TranscriptCollectionView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptCollectionView is the collection view with the transcript's
/// keyboard: Up and Down move the focused row, Left and Right move through
/// its actions (Copy block, a link), Return runs the focused one, Space
/// toggles the focused bubble and Escape clears the selection. Command C
/// copies. Shift with Up or Down extends the selection, Shift Command A
/// selects the focused message's text and Command A the loaded messages.
/// Shift F10 or the context menu key opens the focused row's menu, and End or
/// Command Down goes to the end. Every one of them is a key, never a hover
/// (§3.3, §12.5).
///
/// It decides nothing itself; each key calls the controller's closure.
@MainActor
final class TranscriptCollectionView: NSCollectionView {

    var onMove      : ((Int) -> Void)?
    var onMoveAction: ((Int) -> Void)?
    var onActivate  : (() -> Void)?
    var onCopy      : (() -> Void)?
    var onExtend    : ((Int) -> Void)?
    var onSelectAll : (() -> Void)?
    var onSelectMessage: (() -> Void)?
    var onContextMenu  : (() -> Void)?
    var onScrollToEnd  : (() -> Void)?
    var onToggle       : (() -> Void)?
    var onClear        : (() -> Void)?

    /// Called before any key is handled, so the focus outline shows for the keyboard and not after a click.
    var onKeyboard     : (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyboard?()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The letter, not the key position, so the chord follows the keyboard layout.
        if modifiers.isSuperset(of: [.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSelectMessage?()
            return
        }
        // Command C reaches here only when no menu item took it, as in a window without an Edit menu.
        if modifiers.subtracting([.numericPad, .function]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopy?()
            return
        }
        switch event.keyCode {
        case 109 where modifiers.contains(.shift), 110: onContextMenu?()
        case 119: onScrollToEnd?()
        case 125 where modifiers.contains(.command): onScrollToEnd?()
        case 126 where modifiers.contains(.shift): onExtend?(-1)
        case 125 where modifiers.contains(.shift): onExtend?(1)
        case 126: onMove?(-1)
        case 125: onMove?(1)
        case 123: onMoveAction?(-1)
        case 124: onMoveAction?(1)
        case 49: onToggle?()
        case 53: onClear?()
        case 36, 76: onActivate?()
        default: super.keyDown(with: event)
        }
    }

    /// A press that reaches the collection view itself is on empty space.
    override func mouseDown(with event: NSEvent) {
        onClear?()
        super.mouseDown(with: event)
    }

    @objc
    func copy(_ sender: Any?) {
        onCopy?()
    }

    /// Edit, Select All, which the first responder receives: the loaded
    /// messages as bubbles, never the collection view's own item selection.
    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }
}

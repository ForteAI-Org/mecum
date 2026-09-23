//
//  TranscriptCollectionView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptCollectionView is the collection view with the transcript's
/// keyboard: Up and Down move the focused row, Left and Right move through
/// its actions (Copy block, a link), Return and Space run the focused one,
/// Command C copies. Shift with Up or Down extends the selection by row,
/// Shift Command A selects the focused message and Command A the loaded
/// rows. Every one of them is a key, never a hover (§3.3, §12.5).
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

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The letter, not the key position, so the chord follows the keyboard layout.
        if modifiers.isSuperset(of: [.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSelectMessage?()
            return
        }
        switch event.keyCode {
        case 126 where modifiers.contains(.shift): onExtend?(-1)
        case 125 where modifiers.contains(.shift): onExtend?(1)
        case 126: onMove?(-1)
        case 125: onMove?(1)
        case 123: onMoveAction?(-1)
        case 124: onMoveAction?(1)
        case 36, 76, 49: onActivate?()
        default: super.keyDown(with: event)
        }
    }

    @objc
    func copy(_ sender: Any?) {
        onCopy?()
    }

    /// Edit, Select All, which the first responder receives: the transcript's
    /// loaded rows, never the collection view's own item selection.
    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }
}

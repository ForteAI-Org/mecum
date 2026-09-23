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
/// Command C copies. Every one of them is a key, never a hover (§3.3).
///
/// It decides nothing itself; each key calls the controller's closure.
@MainActor
final class TranscriptCollectionView: NSCollectionView {

    var onMove      : ((Int) -> Void)?
    var onMoveAction: ((Int) -> Void)?
    var onActivate  : (() -> Void)?
    var onCopy      : (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
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
}

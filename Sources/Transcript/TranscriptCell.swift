//
//  TranscriptCell.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptCell is the recycled collection view item every row uses. It
/// owns one `TranscriptRowView`, and its selection is the keyboard focus the
/// row draws as an outline.
@MainActor
final class TranscriptCell: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("TranscriptCell")

    let rowView = TranscriptRowView()

    override func loadView() {
        view = rowView
    }

    override var isSelected: Bool {
        didSet { rowView.isFocusedRow = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        view.layer?.removeAllAnimations()
        view.alphaValue = 1
    }

    /// A short entrance for a row that just arrived (§11.4). Reduce Motion
    /// keeps the fade and drops the movement.
    func playEntrance(reducesMotion: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue   = 1
        let group = CAAnimationGroup()
        group.duration       = 0.17
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if reducesMotion {
            group.animations = [fade]
        } else {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 8
            rise.toValue   = 0
            group.animations = [fade, rise]
        }
        layer.add(group, forKey: "entrance")
    }
}

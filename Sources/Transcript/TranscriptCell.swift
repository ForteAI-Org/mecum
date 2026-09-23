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
        view.layer?.mask = nil
        view.alphaValue = 1
    }

    /// Moves the row from `shift` points off its place back onto it and, for
    /// a row that grew, uncovers it downwards from `height`, so the rows an
    /// expansion pushes never show through it.
    func slide(from shift: CGFloat, openingFrom height: CGFloat?) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        if abs(shift) > 0.5 {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue      = shift
            move.toValue        = 0
            move.duration       = 0.22
            move.timingFunction = timing
            layer.add(move, forKey: "slide")
        }
        guard let height, height < layer.bounds.height else { return }
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        // The edge that stays put is the row's top, wherever the layer's geometry puts it.
        mask.anchorPoint = CGPoint(x: 0, y: layer.contentsAreFlipped() ? 0 : 1)
        mask.frame       = layer.bounds
        layer.mask       = mask
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer, weak mask] in
            if let layer, layer.mask === mask { layer.mask = nil }
        }
        let open = CABasicAnimation(keyPath: "bounds.size.height")
        open.fromValue      = height
        open.toValue        = layer.bounds.height
        open.duration       = 0.22
        open.timingFunction = timing
        mask.add(open, forKey: "open")
        CATransaction.commit()
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

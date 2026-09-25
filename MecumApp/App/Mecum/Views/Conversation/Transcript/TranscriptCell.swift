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

    /// The card a closing tool line lost, folding away under the row.
    private var folded: NSImageView?

    /// How long a row takes to slide, open or fold.
    private static let motion: CFTimeInterval = 0.22

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
        folded?.removeFromSuperview()
        folded = nil
    }

    /// Moves the row from `shift` points off its place back onto it and, for
    /// a row that grew, uncovers it downwards from `height` as the part it
    /// gained fades in, so the rows an expansion pushes never show through it.
    func slide(from shift: CGFloat, openingFrom height: CGFloat?) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        if abs(shift) > 0.5 {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue      = shift
            move.toValue        = 0
            move.duration       = Self.motion
            move.timingFunction = timing
            layer.add(move, forKey: "slide")
        }
        guard let height, height < layer.bounds.height else { return }
        // The edge that stays put is the row's top, wherever the layer's geometry puts it.
        let isFlipped = layer.contentsAreFlipped()
        let whole     = layer.bounds
        let gained    = whole.height - height
        let kept      = CALayer()
        let opened    = CALayer()
        kept.backgroundColor   = NSColor.black.cgColor
        opened.backgroundColor = NSColor.black.cgColor
        kept.frame         = CGRect(x: 0, y: isFlipped ? 0 : gained, width: whole.width, height: height)
        opened.anchorPoint = CGPoint(x: 0, y: isFlipped ? 0 : 1)
        opened.frame       = CGRect(x: 0, y: isFlipped ? height : 0, width: whole.width, height: gained)
        let mask = CALayer()
        mask.frame = whole
        mask.addSublayer(kept)
        mask.addSublayer(opened)
        layer.mask = mask
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer, weak mask] in
            if let layer, layer.mask === mask { layer.mask = nil }
        }
        let open = CABasicAnimation(keyPath: "bounds.size.height")
        open.fromValue = 0
        open.toValue   = gained
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue   = 1
        let group = CAAnimationGroup()
        group.animations     = [open, fade]
        group.duration       = Self.motion
        group.timingFunction = timing
        opened.add(group, forKey: "open")
        CATransaction.commit()
    }

    /// Shows `card`, what the row lost as it closed, under its new bottom edge, and folds
    /// it up into that edge as it fades out, in step with the rows under it sliding up.
    func fold(_ card: NSImage) {
        folded?.removeFromSuperview()
        let overlay = NSImageView(frame: CGRect(origin: CGPoint(x: 0, y: view.bounds.height), size: card.size))
        overlay.image        = card
        overlay.imageScaling = .scaleNone
        overlay.wantsLayer   = true
        // Only a picture of what was there: VoiceOver reads the row itself.
        overlay.setAccessibilityElement(false)
        view.addSubview(overlay)
        folded = overlay
        guard let layer = overlay.layer else { return }
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint     = CGPoint(x: 0, y: layer.contentsAreFlipped() ? 0 : 1)
        mask.frame           = layer.bounds
        layer.mask           = mask
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            if let self, self.folded === overlay { self.folded = nil }
        }
        let shrink = CABasicAnimation(keyPath: "bounds.size.height")
        shrink.fromValue = layer.bounds.height
        shrink.toValue   = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue   = 0
        let group = CAAnimationGroup()
        // It holds its end, invisible, until the completion takes the overlay away.
        group.animations            = [shrink, fade]
        group.duration              = Self.motion
        group.timingFunction        = CAMediaTimingFunction(name: .easeInEaseOut)
        group.fillMode              = .forwards
        group.isRemovedOnCompletion = false
        mask.add(group, forKey: "fold")
        CATransaction.commit()
    }

    /// A short entrance for a row that just arrived (§11.4), or a slower one for
    /// each row of a conversation just opened in place of another. Reduce Motion
    /// keeps the fade and drops the movement.
    func playEntrance(reducesMotion: Bool, duration: CFTimeInterval = 0.17) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue   = 1
        let group = CAAnimationGroup()
        group.duration       = duration
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

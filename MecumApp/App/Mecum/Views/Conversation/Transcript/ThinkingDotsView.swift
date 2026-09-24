//
//  ThinkingDotsView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// ThinkingDotsView draws the three dots of a thinking bubble and breathes
/// them one after another, softly. Under Reduce Motion they stay still.
///
/// Each dot draws itself, so an offscreen snapshot shows them; the animation
/// is on their layers' opacity and costs no redraw. It takes no clicks: the
/// row under it keeps its focus and selection. Main actor only.
@MainActor
final class ThinkingDotsView: NSView {

    /// One dot, filled in the secondary label colour of its appearance.
    private final class Dot: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }

    private static let animationKey = "thinking"

    private let dots = (0..<3).map { _ in Dot() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dots.forEach { dot in
            dot.wantsLayer = true
            addSubview(dot)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let side = (bounds.height * 0.42).rounded()
        let gap  = max(0, (bounds.width - 3 * side) / 2)
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * (side + gap), y: ((bounds.height - side) / 2).rounded(),
                               width: side, height: side)
        }
    }

    /// Starts the breathing, staggered from the first dot, unless it runs
    /// already, so a reconfigured row does not restart it. Reduce Motion stops it.
    func start(reducesMotion: Bool) {
        needsLayout = true
        guard !reducesMotion else {
            stop()
            return
        }
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            guard let layer = dot.layer, layer.animation(forKey: Self.animationKey) == nil else { continue }
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue      = 1
            breath.toValue        = 0.3
            breath.duration       = 0.6
            breath.autoreverses   = true
            breath.repeatCount    = .infinity
            breath.beginTime      = now + Double(index) * 0.2
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(breath, forKey: Self.animationKey)
        }
    }

    func stop() {
        dots.forEach { $0.layer?.removeAnimation(forKey: Self.animationKey) }
    }
}

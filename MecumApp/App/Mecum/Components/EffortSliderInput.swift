//
//  EffortSliderInput.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import SwiftUI

/// EffortSliderInput is the surface an `EffortSlider` is pressed and dragged
/// on. While `holdsPointer`, a drag hides the pointer and detaches it from
/// the hand, so what arrives is the hand's own motion, which the slider may
/// turn into less motion of the knob; the slider draws the pointer where the
/// knob holds it. When the drag ends the real pointer comes back there.
/// Moving the real pointer on every event instead would feed each move back
/// into the next event's motion, and the knob would shake back and forth.
///
/// The pointer is always given back: on release, when the view leaves its
/// window and when the app stops being active.
struct EffortSliderInput: NSViewRepresentable {

    /// False under Reduce Motion: the pointer stays the hand's, and the knob follows its position.
    let holdsPointer: Bool

    /// A press at a point in the slider's coordinates, from its top-leading corner.
    let press: (CGPoint) -> Void

    /// The hand moved by `delta` points, with the pointer at `x`.
    let drag: (_ delta: CGFloat, _ x: CGFloat) -> Void

    /// The drag ended; answers where the knob settles, for the pointer to come back to.
    let release: () -> CGFloat?

    func makeNSView(context: Context) -> Surface {
        Surface()
    }

    func updateNSView(
        _ surface: Surface,
        context  : Context
    ) {
        surface.holdsPointer = holdsPointer
        surface.press        = press
        surface.drag         = drag
        surface.release      = release
    }

    final class Surface: NSView {

        var holdsPointer = true
        var press  : (CGPoint) -> Void           = { _ in }
        var drag   : (CGFloat, CGFloat) -> Void  = { _, _ in }
        var release: () -> CGFloat?              = { nil }

        /// True while the pointer is hidden and detached for a drag.
        private var isHolding = false

        /// True from a press to its first drag, whose motion is not the hand's (see `mouseDragged`).
        private var isFirstDrag = false

        private var resignation: NSObjectProtocol?

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            isFirstDrag = true
            press(convert(event.locationInWindow, from: nil))
            if holdsPointer { hold() }
        }

        /// The first drag after a press carries, besides the hand's first point or two, the whole
        /// move the pointer was put back with after the last drag, when nothing moved in between:
        /// macOS counts that move as motion and hands it over with the next motion event. So that
        /// drag's motion is dropped.
        override func mouseDragged(with event: NSEvent) {
            var delta = event.deltaX
            if isFirstDrag {
                isFirstDrag = false
                delta = 0
            }

            drag(
                delta,
                convert(event.locationInWindow, from: nil).x
            )
        }

        override func mouseUp(with event: NSEvent) {
            letGo(at: release())
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { letGo(at: nil) }
        }

        // MARK: The pointer

        private func hold() {
            guard !isHolding else { return }

            isHolding = true
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(0)
            resignation = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object : nil,
                queue  : .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.letGo(at: nil) }
            }
        }

        /// Gives the pointer back, over the knob at `x` when there is one.
        private func letGo(at x: CGFloat?) {
            guard isHolding else { return }

            isHolding = false
            if let x { place(at: x) }
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            if let resignation { NotificationCenter.default.removeObserver(resignation) }
            resignation = nil
        }

        /// Puts the pointer over the knob at `x`, at the height the hand left it.
        private func place(at x: CGFloat) {
            guard let window, let primary = NSScreen.screens.first else { return }

            let onScreen = window.convertPoint(toScreen: convert(NSPoint(x: x, y: bounds.midY), to: nil))
            // Core Graphics counts from the top of the primary display, AppKit from its bottom.
            CGWarpMouseCursorPosition(
                CGPoint(
                    x: onScreen.x,
                    y: primary.frame.maxY - NSEvent.mouseLocation.y
                )
            )
        }
    }
}

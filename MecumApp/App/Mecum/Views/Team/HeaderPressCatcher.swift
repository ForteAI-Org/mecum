//
//  HeaderPressCatcher.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// HeaderPressCatcher hands a press on the worker's header to `onPress`,
/// including where the window would keep it.
///
/// The header rises into the toolbar's band, and there the titlebar takes
/// every press for itself, to drag the window. A local event monitor sees the
/// press first: one in this window, inside this view's frame, goes to `onPress`
/// and no further. Any other press passes untouched. The view draws nothing
/// and takes no hit of its own.
struct HeaderPressCatcher: NSViewRepresentable {

    let onPress: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onPress = onPress
    }

    /// The AppKit end: it watches presses while it is in a window.
    final class CatcherView: NSView {

        var onPress: (() -> Void)?

        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let caught = MainActor.assumeIsolated { self?.catches(event) ?? false }
                return caught ? nil : event
            }
        }

        /// Whether `event` is a press on this view in its window, which it then hands on.
        private func catches(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  convert(bounds, to: nil).contains(event.locationInWindow)
            else { return false }
            onPress?()
            return true
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

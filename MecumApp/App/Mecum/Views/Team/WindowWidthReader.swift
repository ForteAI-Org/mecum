//
//  WindowWidthReader.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// WindowWidthReader reports the width of the window it is in: once when it
/// joins the window and after every resize of that window.
///
/// The width is the `NSWindow` frame's, read from AppKit's resize
/// notification, never a size SwiftUI measured inside the split. A decision
/// taken from it therefore cannot change the value it was taken from, which is
/// what keeps the shell's inspector rule out of the layout pass (§3.1). The
/// view takes no space and asks for none.
struct WindowWidthReader: NSViewRepresentable {

    let onWidth: (Double) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWidth = onWidth
        return view
    }

    func updateNSView(
        _ view : ReaderView,
        context: Context
    ) {
        view.onWidth = onWidth
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView    : ReaderView,
        context   : Context
    ) -> CGSize? {
        .zero
    }

    /// The AppKit end: it watches its window and calls back on the main thread.
    final class ReaderView: NSView {

        var onWidth: ((Double) -> Void)?

        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }

            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object : window,
                queue  : .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // Reported after this pass, so the first decision is not taken inside a layout.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }

            onWidth?(window.frame.width)
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

//
//  TitleBarHeightReader.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/10/2026.
//

import AppKit
import SwiftUI

/// TitleBarHeightReader reports how far its window's title bar and toolbar
/// reach over the content: once when it joins the window and whenever that
/// changes.
///
/// It is the window's own measure, the content above `contentLayoutRect`,
/// watched through key-value observing. The top safe area a SwiftUI view reads
/// is not one to rely on: while the window or the inspector resizes, the
/// conversation's alternates between zero and the bar's height within one
/// update, and every change moved the transcript's rows. The view takes no
/// space and asks for none.
struct TitleBarHeightReader: NSViewRepresentable {

    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onHeight = onHeight
        return view
    }

    func updateNSView(
        _ view : ReaderView,
        context: Context
    ) {
        view.onHeight = onHeight
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

        var onHeight: ((CGFloat) -> Void)?

        private var observation: NSKeyValueObservation?

        private var reported: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            reported    = nil
            guard let window else { return }

            // AppKit changes it on the main thread, with the window's frame and toolbar.
            observation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // Reported after this pass, so the first height is not set inside a layout.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window, let content = window.contentView else { return }

            let height = max(0, content.frame.maxY - window.contentLayoutRect.maxY)
            guard height != reported else { return }

            reported = height
            onHeight?(height)
        }
    }
}

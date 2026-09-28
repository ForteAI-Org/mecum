//
//  ComposerPopupPresenter.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import AppKit
import SwiftUI

/// ComposerPopupPresenter shows a popup above the view it modifies, the
/// composer: its bottom clear of the bar's top and kept inside the composer's
/// width, so it never covers the bar or leaves the window. It rises from the
/// bar as it opens and sinks back into it as it closes, and only fades with
/// Reduce Motion. A click in the window outside the popup and its anchor
/// closes it, and so does Escape unless the composer's field answers Escape
/// for it; `onClose` runs then. The model popup and the command popup are
/// both presented this way.
struct ComposerPopupPresenter<Popup: View>: ViewModifier {

    /// Where the popup sits along the composer, and what a click can land on without closing it.
    enum Placement {

        /// Centred on a control in the bar, whose frame in the window is `anchor`, as it was
        /// when the popup opened. A click on the control is left to it, since it opens and closes the popup.
        case centred(on: CGRect)

        /// At the composer's leading edge. A click anywhere in the composer leaves the popup open.
        case leading
    }

    @Binding var isPresented: Bool

    let placement: Placement

    /// The popup's width, which it keeps whatever it shows.
    let width: CGFloat

    /// Whether Escape closes the popup wherever the keyboard is. False for a popup whose keys the
    /// composer's field answers, which leaves Escape to a composition and passes a second one on.
    let closesOnEscape: Bool

    let onClose: () -> Void

    let popup: () -> Popup

    @State private var composer   = CGRect.zero
    @State private var popupFrame = CGRect.zero

    /// The anchor's centre when the popup opened, which the popup keeps while it is open;
    /// nil for a popup drawn open from the start, which takes the anchor's centre as it is.
    @State private var centre: CGFloat?

    @State private var monitor: Any?

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// The gap between the popup and the bar, and between the popup and the composer's sides.
    static var gap   : CGFloat { 12 }
    static var margin: CGFloat { 16 }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composer = $0 }
            .overlay(alignment: .top) {
                // A frame with no height on the composer's top edge, the popup on its bottom: the
                // popup grows upward from above the bar, and its size changes are laid out, so animated.
                if isPresented {
                    popup()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { popupFrame = $0 }
                        .padding(
                            .bottom,
                            Self.gap
                        )
                        .offset(x: leading)
                        .frame(
                            width    : composer.width,
                            height   : 0,
                            alignment: .bottomLeading
                        )
                        // It rises from the bar as it opens and sinks back into it as it closes.
                        .transition(
                            reducesMotion ? .opacity : .opacity.combined(with: .offset(y: 24))
                        )
                }
            }
            .animation(
                reducesMotion ? nil : .snappy(duration: 0.2),
                value: isPresented
            )
            .onChange(of: isPresented) {
                if isPresented {
                    if case .centred(let anchor) = placement { centre = anchor.midX - composer.minX }
                    watchOutside()
                } else {
                    centre = nil
                    stopWatching()
                    onClose()
                }
            }
            // A popup drawn open from the start, as a draft that is a command opens one, closes the same way.
            .onAppear {
                if isPresented { watchOutside() }
            }
            .onDisappear {
                stopWatching()
                if isPresented { isPresented = false; onClose() }
            }
    }

    /// The popup's leading edge: centred on the anchor, or at the composer's leading edge, inside its width.
    private var leading: CGFloat {
        let ideal = switch placement {
        case .centred(let anchor): (centre ?? anchor.midX - composer.minX) - width / 2
        case .leading            : Self.margin
        }
        return min(
            max(
                ideal,
                Self.margin
            ),
            max(
                composer.width - Self.margin - width,
                Self.margin
            )
        )
    }

    /// What a click can land on, besides the popup, without closing it.
    private var anchor: CGRect {
        switch placement {
        case .centred(let anchor): anchor
        case .leading            : composer
        }
    }

    // MARK: Closing

    /// Closes on Escape, when it may, and on a click in the window that lands outside both the
    /// anchor and the popup; the click still reaches what it landed on.
    private func watchOutside() {
        guard monitor == nil else { return }

        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard closesOnEscape, event.keyCode == 53 else { return event }
                isPresented = false
                return nil
            }

            guard event.window === window, let height = window?.contentView?.bounds.height else { return event }
            // The window's point from its bottom-left corner, as SwiftUI's global frames measure from the top.
            let point = CGPoint(
                x: event.locationInWindow.x,
                y: height - event.locationInWindow.y
            )
            if !anchor.contains(point), !popupFrame.contains(point) { isPresented = false }
            return event
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {

    /// Presents `popup` above this view, the composer; see `ComposerPopupPresenter`.
    func composerPopup<Popup: View>(
        isPresented   : Binding<Bool>,
        placement     : ComposerPopupPresenter<Popup>.Placement,
        width         : CGFloat,
        closesOnEscape: Bool = true,
        onClose       : @escaping () -> Void = {},
        @ViewBuilder popup: @escaping () -> Popup
    ) -> some View {
        modifier(
            ComposerPopupPresenter(
                isPresented   : isPresented,
                placement     : placement,
                width         : width,
                closesOnEscape: closesOnEscape,
                onClose       : onClose,
                popup         : popup
            )
        )
    }
}

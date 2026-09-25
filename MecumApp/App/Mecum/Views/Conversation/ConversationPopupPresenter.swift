//
//  ConversationPopupPresenter.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import ModelTransports
import SwiftUI

/// ConversationPopupPresenter shows a popup, the model popup or the context
/// popup, above the view it modifies: its bottom clear of that view's top,
/// centred on the button that opens it as it was when the popup opened, and
/// kept inside the view's width, so it never covers the composer or leaves the
/// window. A click in the window outside the button and the popup, or Escape,
/// closes it, and `onClose` runs then.
struct ConversationPopupPresenter<Popup: View>: ViewModifier {

    @Binding var isPresented: Bool

    /// The opening button's frame in the window.
    let button: CGRect

    /// The popup's own fixed width, which keeps it inside the composer's.
    let width: CGFloat

    let onClose: () -> Void

    @ViewBuilder
    let popup: () -> Popup

    @State private var composer = CGRect.zero
    @State private var frame    = CGRect.zero

    /// The button's centre when the popup opened, which the popup keeps while it is open;
    /// nil for a popup drawn open from the start, which takes the button's centre as it is.
    @State private var centre: CGFloat?

    @State private var monitor: Any?

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// The gap between the popup and the bar, and between the popup and the composer's sides.
    private static var gap   : CGFloat { 12 }
    private static var margin: CGFloat { 16 }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composer = $0 }
            .overlay(alignment: .top) {
                // A frame with no height on the composer's top edge, the popup on its bottom: the
                // popup grows upward from above the bar, and its size changes are laid out, so animated.
                if isPresented {
                    popup()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
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
            .animation(reducesMotion ? nil : .snappy(duration: 0.2), value: isPresented)
            .onChange(of: isPresented) {
                if isPresented {
                    centre = button.midX - composer.minX
                    watchOutside()
                } else {
                    centre = nil
                    stopWatching()
                    onClose()
                }
            }
            .onDisappear {
                stopWatching()
                if isPresented { isPresented = false; onClose() }
            }
    }

    /// The popup's leading edge: centred on the button, inside the composer's width.
    private var leading: CGFloat {
        let ideal = (centre ?? button.midX - composer.minX) - width / 2
        return min(max(ideal, Self.margin), max(composer.width - Self.margin - width, Self.margin))
    }

    // MARK: Closing

    /// Closes on Escape, and on a click in the window that lands outside both the button and the
    /// popup; the click still reaches what it landed on.
    private func watchOutside() {
        guard monitor == nil else { return }

        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                isPresented = false
                return nil
            }

            guard event.window === window, let height = window?.contentView?.bounds.height else { return event }
            // The window's point from its bottom-left corner, as SwiftUI's global frames measure from the top.
            let point = CGPoint(
                x: event.locationInWindow.x,
                y: height - event.locationInWindow.y
            )
            if !button.contains(point), !frame.contains(point) { isPresented = false }
            return event
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {

    /// Presents `popup`, `width` wide, above this view; see `ConversationPopupPresenter`.
    func composerPopup(
        isPresented: Binding<Bool>,
        button     : CGRect,
        width      : CGFloat,
        onClose    : @escaping () -> Void = {},
        @ViewBuilder popup: @escaping () -> some View
    ) -> some View {
        modifier(
            ConversationPopupPresenter(
                isPresented: isPresented,
                button     : button,
                width      : width,
                onClose    : onClose,
                popup      : popup
            )
        )
    }

    /// Presents the composer's model popup above this view.
    func modelPopup(
        isPresented: Binding<Bool>,
        button     : CGRect,
        selection  : Binding<ModelSelection>,
        catalogue  : [ModelInfo]?,
        onClose    : @escaping () -> Void
    ) -> some View {
        composerPopup(
            isPresented: isPresented,
            button     : button,
            width      : ConversationModelPopup.width,
            onClose    : onClose
        ) {
            ConversationModelPopup(
                selection: selection,
                catalogue: catalogue
            )
        }
    }
}

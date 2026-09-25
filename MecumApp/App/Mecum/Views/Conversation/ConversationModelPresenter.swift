//
//  ConversationModelPresenter.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import ModelTransports
import SwiftUI

/// ConversationModelPresenter shows `ConversationModelPopup` above the view it
/// modifies, the composer: its bottom clear of the bar's top, centred on the
/// model button as it was when the popup opened, and kept inside the
/// composer's width, so it never covers the bar or leaves the window. A click
/// in the window outside the button and the popup, or Escape, closes it, and
/// `onClose` runs then.
struct ConversationModelPresenter: ViewModifier {

    @Binding var isPresented: Bool

    /// The model button's frame in the window.
    let button: CGRect

    @Binding var selection: ModelSelection

    let catalogue: [ModelInfo]?

    let onClose: () -> Void

    @State private var composer = CGRect.zero
    @State private var popup    = CGRect.zero

    /// The button's centre when the popup opened, which the popup keeps while it is open;
    /// nil for a popup drawn open from the start, which takes the button's centre as it is.
    @State private var centre: CGFloat?

    @State private var monitor: Any?

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// The gap between the popup and the bar, and between the popup and the composer's sides.
    private static let gap   : CGFloat = 12
    private static let margin: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composer = $0 }
            .overlay(alignment: .top) {
                // A frame with no height on the composer's top edge, the popup on its bottom: the
                // popup grows upward from above the bar, and its size changes are laid out, so animated.
                if isPresented {
                    ConversationModelPopup(
                        selection: $selection,
                        catalogue: catalogue
                    )
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { popup = $0 }
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
        let width = ConversationModelPopup.width
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
            if !button.contains(point), !popup.contains(point) { isPresented = false }
            return event
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {

    /// Presents the composer's model popup above this view; see `ConversationModelPresenter`.
    func modelPopup(
        isPresented: Binding<Bool>,
        button     : CGRect,
        selection  : Binding<ModelSelection>,
        catalogue  : [ModelInfo]?,
        onClose    : @escaping () -> Void
    ) -> some View {
        modifier(
            ConversationModelPresenter(
                isPresented: isPresented,
                button     : button,
                selection  : selection,
                catalogue  : catalogue,
                onClose    : onClose
            )
        )
    }
}

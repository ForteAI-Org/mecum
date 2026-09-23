//
//  SidebarBridge.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// SidebarBridge sets the one thing the team sidebar needs from AppKit that
/// SwiftUI has no modifier for: the split item it is in never collapses.
///
/// It reaches the views SwiftUI built through public API only: up from itself
/// to the enclosing `NSSplitView`, to that view's `NSSplitViewController` and
/// the item whose view holds the bridge, where `canCollapse` becomes false.
/// SwiftUI sets the item back each time it updates the split, so the bridge
/// observes the property and answers every change; a drag of the divider then
/// stops at the column's minimum, and `toggleSidebar:` finds nothing to collapse.
///
/// It depends on SwiftUI hosting the split in an `NSSplitViewController`, as
/// macOS 26 does. Without the split item the shell's guard on the column
/// visibility still reopens a sidebar that went. Outside a split, as in the
/// offscreen snapshot, it changes nothing. The view takes no space and draws
/// nothing.
struct SidebarBridge: NSViewRepresentable {

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ view: BridgeView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BridgeView, context: Context) -> CGSize? {
        .zero
    }

    /// The AppKit end: it finds the split item once it is in a window.
    final class BridgeView: NSView {

        private weak var item: NSSplitViewItem?

        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard window != nil else { return }
            // The split is assembled around this view in the same pass, and completes after it.
            DispatchQueue.main.async { [weak self] in self?.connect() }
        }

        private func connect() {
            guard observation == nil, let item = splitItem() else { return }
            self.item = item
            reapply()
            // SwiftUI changes it on the main thread, as AppKit requires of split items.
            observation = item.observe(\.canCollapse) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reapply() }
            }
        }

        private func reapply() {
            if let item, item.canCollapse { item.canCollapse = false }
        }

        /// The split item holding this view, or nil outside a split.
        private func splitItem() -> NSSplitViewItem? {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first(where: { isDescendant(of: $0.viewController.view) }) {
                    return item
                }
                ancestor = view.superview
            }
            return nil
        }
    }
}

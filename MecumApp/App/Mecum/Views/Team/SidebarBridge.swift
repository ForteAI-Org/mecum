//
//  SidebarBridge.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// SidebarBridge sets the two things the team sidebar needs from AppKit that
/// SwiftUI has no modifier for: the split item it is in never collapses, and
/// its list draws no selection of its own, since each block draws it.
///
/// It reaches the views SwiftUI built through public API only: up from itself
/// to the enclosing `NSSplitView`, to that view's `NSSplitViewController` and
/// the item whose view holds the bridge, where `canCollapse` becomes false; and
/// down from that view to the list's `NSTableView`, whose
/// `selectionHighlightStyle` becomes `.none`. Selection, the arrow keys, type
/// select and assistive technology are the table's as before. SwiftUI sets the
/// split item back each time it updates the split, so the bridge observes both
/// properties and answers every change; a drag of the divider then stops at the
/// column's minimum, and `toggleSidebar:` finds nothing to collapse.
///
/// It depends on SwiftUI hosting the split in an `NSSplitViewController` and
/// the list in an `NSTableView`, as macOS 26 does. Without the split item the
/// shell's guard on the column visibility still reopens a sidebar that went;
/// without the table the system's selection draws under the blocks. Outside a
/// split, as in the offscreen snapshot, only the table is changed. The view
/// takes no space and draws nothing.
struct SidebarBridge: NSViewRepresentable {

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ view: BridgeView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BridgeView, context: Context) -> CGSize? {
        .zero
    }

    /// The AppKit end: it finds the split item and the table once it is in a window.
    final class BridgeView: NSView {

        private weak var item : NSSplitViewItem?
        private weak var table: NSTableView?

        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations = []
            guard window != nil else { return }
            // The split and the list are assembled around this view in the same pass, and complete after it.
            DispatchQueue.main.async { [weak self] in self?.connect() }
        }

        private func connect() {
            guard observations.isEmpty else { return }
            let (item, container) = splitItem()
            self.item  = item
            self.table = Self.firstTable(in: container ?? window?.contentView)
            reapply()
            // SwiftUI changes both on the main thread, as AppKit requires of views and split items.
            if let item {
                observations.append(item.observe(\.canCollapse) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.reapply() }
                })
            }
            if let table {
                observations.append(table.observe(\.selectionHighlightStyle) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.reapply() }
                })
            }
        }

        private func reapply() {
            if let item, item.canCollapse { item.canCollapse = false }
            if let table, table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
        }

        /// The split item holding this view and that item's view, or nils outside a split.
        private func splitItem() -> (NSSplitViewItem?, NSView?) {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first(where: { isDescendant(of: $0.viewController.view) }) {
                    return (item, item.viewController.view)
                }
                ancestor = view.superview
            }
            return (nil, nil)
        }

        /// The first table under `root`, breadth first.
        private static func firstTable(in root: NSView?) -> NSTableView? {
            var queue = root.map { [$0] } ?? []
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let table = view as? NSTableView { return table }
                queue += view.subviews
            }
            return nil
        }
    }
}

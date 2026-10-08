//
//  ShellMetrics.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// ShellMetrics holds the team window's width tokens (§3.1) and the rule that
/// divides a window between the sidebar, the conversation and the inspector.
///
/// The sidebar is never hidden. It is full at `sidebar.ideal`, or compact at
/// `compactSidebar`, where each worker is a tile with its mascot and name. The
/// columns are laid out at these constants, and the division is decided from
/// the window's own width and never from a width measured inside the split,
/// so no decision can feed back into the layout that produced it. The
/// conversation is never left less than `conversationMinimum`: when the
/// inspector does not fit beside the full sidebar, the sidebar turns compact
/// first, and only when it does not fit beside the compact one either does it
/// close.
nonisolated enum ShellMetrics {

    /// How far the person may drag the full sidebar. Narrower than `minimum`
    /// its rows no longer read, and it shows the compact tiles instead.
    static let sidebar   = ColumnWidth(ideal: 280, minimum: 200, maximum: 340)
    static let inspector = ColumnWidth(ideal: 360, minimum: 320, maximum: 440)

    /// The compact sidebar: a 32 point mascot and its name under it, in a tile
    /// that clears the window's traffic lights. It is also the narrowest the
    /// person can drag the sidebar, and wide enough for the traffic lights
    /// (79 points), the toolbar's gap (17) and New Worker (36) with its 8 point
    /// inset, so the button never goes into the toolbar's overflow menu.
    static let compactSidebar: Double = 140

    /// The narrowest conversation whose bubbles still read: a short bubble is
    /// 34 ems of the 14 point body (476 points), less the margins it gives up.
    static let conversationMinimum: Double = 460

    /// How much wider than the line a resize must go before a column that gave
    /// way comes back, so a resize across the line does not flip it twice.
    static let hysteresis: Double = 24

    /// What the window shows while the person has asked for the inspector.
    struct Division: Sendable, Hashable {

        let isInspectorShown: Bool
        let isSidebarCompact: Bool

        init(isInspectorShown: Bool, isSidebarCompact: Bool) {
            self.isInspectorShown = isInspectorShown
            self.isSidebarCompact = isSidebarCompact
        }

        /// The inspector closed and the sidebar full, as every window starts.
        static let withoutInspector = Division(isInspectorShown: false, isSidebarCompact: false)
    }

    /// The conversation beside the wider of the full sidebar and the compact
    /// sidebar with the inspector, so the inspector can always open.
    static var windowMinimum: Double {
        conversationMinimum + max(sidebar.ideal, compactSidebar + inspector.ideal)
    }

    /// The window's minimum while the inspector is asked for or shown: the
    /// conversation beside the compact sidebar. AppKit adds the inspector's own
    /// width to the window's minimum, and an inspector opened in a window
    /// narrower than that sum keeps the conversation's width and pushes the
    /// window wider instead, so the minimum drops to this before it opens.
    static var windowMinimumBesideInspector: Double {
        conversationMinimum + compactSidebar
    }

    /// Whether a sidebar `width` points wide shows the compact tiles.
    static func showsCompactTiles(sidebarWidth width: Double) -> Bool {
        width < sidebar.minimum
    }

    /// How a window `window` points wide is divided when the inspector is
    /// asked for. `previous` is what the window showed before a resize, and nil
    /// for a request or a restore, which are decided once: after a resize, what
    /// is shown stays while it fits, and a column that gave way comes back only
    /// with `hysteresis` to spare.
    static func division(window: Double, previous: Division?) -> Division {
        let wasFull = previous == Division(isInspectorShown: true, isSidebarCompact: false)
        let wasShown = previous?.isInspectorShown ?? false
        if room(window: window, sidebar: sidebar.ideal) >= inspector.ideal + margin(previous, kept: wasFull) {
            return Division(isInspectorShown: true, isSidebarCompact: false)
        }
        if room(window: window, sidebar: compactSidebar) >= inspector.ideal + margin(previous, kept: wasShown) {
            return Division(isInspectorShown: true, isSidebarCompact: true)
        }
        return .withoutInspector
    }

    /// No margin for a first decision or for what is already shown, `hysteresis` for a return.
    private static func margin(_ previous: Division?, kept: Bool) -> Double {
        previous == nil || kept ? 0 : hysteresis
    }

    /// What the window leaves for the inspector once the sidebar and the conversation have theirs.
    private static func room(window: Double, sidebar: Double) -> Double {
        window - sidebar - conversationMinimum
    }
}

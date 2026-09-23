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
/// The columns are laid out at these constants, and whether the inspector is
/// shown is decided from the window's own width and never from a width
/// measured inside the split, so no decision can feed back into the layout
/// that produced it. The conversation is never left less than
/// `conversationMinimum`: when the three do not fit, the inspector closes
/// first. The sidebar is only hidden when the person explicitly opens the
/// inspector in a window too narrow for both.
public enum ShellMetrics {

    public static let sidebar   = ColumnWidth(ideal: 280, minimum: 250, maximum: 340)
    public static let inspector = ColumnWidth(ideal: 360, minimum: 320, maximum: 440)

    /// The narrowest conversation whose bubbles still read: a short bubble is
    /// 34 ems of the 14 point body (476 points), less the margins it gives up.
    public static let conversationMinimum: Double = 460

    /// How much wider than the line a resize must go before a closed inspector
    /// comes back, so a resize across the line does not open and close it twice.
    public static let hysteresis: Double = 24

    /// The conversation beside the wider of the two columns, so the inspector
    /// can always open once the sidebar gives way.
    public static var windowMinimum: Double {
        conversationMinimum + max(sidebar.ideal, inspector.ideal)
    }

    /// Whether the inspector fits beside the conversation in a window `window`
    /// points wide: the test for an explicit request and for a restored one.
    public static func fitsInspector(window: Double, isSidebarShown: Bool) -> Bool {
        room(window: window, isSidebarShown: isSidebarShown) >= inspector.ideal
    }

    /// Whether the inspector is shown after the window was resized to
    /// `window`, when the person has asked for it. A shown one stays while it
    /// fits; a closed one comes back only with `hysteresis` to spare.
    public static func showsInspectorAfterResize(window: Double, isSidebarShown: Bool, isShown: Bool) -> Bool {
        room(window: window, isSidebarShown: isSidebarShown) >= inspector.ideal + (isShown ? 0 : hysteresis)
    }

    /// Whether opening the inspector on request has to hide the sidebar: it
    /// does not fit beside the sidebar, and does without it.
    public static func openingHidesSidebar(window: Double) -> Bool {
        !fitsInspector(window: window, isSidebarShown: true) && fitsInspector(window: window, isSidebarShown: false)
    }

    /// What the window leaves for the inspector once the conversation has its minimum.
    private static func room(window: Double, isSidebarShown: Bool) -> Double {
        window - (isSidebarShown ? sidebar.ideal : 0) - conversationMinimum
    }
}

//
//  AppPreferences.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

/// AppPreferences names the app's own settings, which Settings edits and
/// the views read through `@AppStorage`, each key with its default beside it
/// so every reader starts from the same value. The provider settings are not
/// here: they belong to `ModelSettingsStore`.
enum AppPreferences {

    // MARK: General

    /// Whether every connection is checked in the background as the app starts.
    static let checksConnectionsAtLaunch        = "general.checksConnectionsAtLaunch"
    static let checksConnectionsAtLaunchDefault = true

    /// The font family of the conversation's text; empty is the system font.
    static let chatFontFamily        = "chat.fontFamily"
    static let chatFontFamilyDefault = ""

    // MARK: Computer

    /// The virtual display a worker's seat is made with, as `SeatDisplay`'s width by height in pixels.
    static let seatDisplaySize        = "computer.displaySize"
    static let seatDisplaySizeDefault = "2560x1440"

    /// The virtual display's refresh rate in hertz, 60 or 120.
    static let seatRefreshRate        = "computer.refreshRate"
    static let seatRefreshRateDefault = 60

    // MARK: Sidebar

    /// Whether a worker's row shows its model under the name when nothing else is said there.
    static let sidebarShowsModel        = "sidebar.showsModel"
    static let sidebarShowsModelDefault = true

    /// Whether a worker's row counts its unread messages. A failed turn is marked either way.
    static let sidebarShowsUnreadCount        = "sidebar.showsUnreadCount"
    static let sidebarShowsUnreadCountDefault = true

    /// Whether the sidebar has a field to find a worker by name.
    static let sidebarShowsSearch        = "sidebar.showsSearch"
    static let sidebarShowsSearchDefault = true

    // MARK: Chat

    /// Whether the time is written under the messages.
    static let chatShowsTimes        = "chat.showsTimes"
    static let chatShowsTimesDefault = true

    /// Whether Return starts a new line and Command-Return sends, instead of Return sending.
    static let chatSendsWithCommandReturn        = "chat.sendsWithCommandReturn"
    static let chatSendsWithCommandReturnDefault = false

    /// Whether a turn's tool steps are shown open rather than as one summary line.
    static let chatOpensToolSteps        = "chat.opensToolSteps"
    static let chatOpensToolStepsDefault = false

    /// Whether a Claude Code or Codex worker may search the web and read pages with its own tools.
    /// A turn reads it as it starts.
    static let workersSearchWeb        = "chat.workersSearchWeb"
    static let workersSearchWebDefault = true

    /// The stored value of a Bool preference in `defaults`, its default when none is stored.
    static func bool(
        _ key           : String,
        default fallback: Bool,
        in defaults     : UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}

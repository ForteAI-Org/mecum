//
//  AppModel.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import BrowserCore
import ChromeBrowser
import ModelTransports
import SeatBroker

/// AppModel is what every window of the app shares: the seat broker the
/// workers' desktops go through, the model settings and the passive watcher.
///
/// Every connection is checked once as the app starts, in the background, so
/// the sidebar's badge and the workers' models are known before anyone opens
/// Connections, unless Settings > General turns it off. A check or test run
/// checks nothing: it would run the `codex` and `claude` command lines for real.
@MainActor
final class AppModel {

    let broker = SeatBroker(configuration: .init(allowUnvalidatedBuild: true))

    let settings = ModelSettingsStore()

    /// One passive watcher shared by every window; construction starts no listener.
    let watcher = WatcherModel()

    let browserSessions = BrowserSessionPool { ChromeBrowser(configuration: .standard()) }

    lazy var externalSessions = MCPAppSessions(broker: broker, browser: browserSessions,
                                               watcher: watcher, support: WorkspaceLaunch.directory)
    lazy var mcp = MCPConnectionsModel(
        directory: WorkspaceLaunch.directory.appendingPathComponent("MCP", isDirectory: true),
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mecum-bridge"),
        makeSession: { [externalSessions] profile, activity, stalled in
            externalSessions.make(profile, activity: activity, stalled: stalled) }
    )

    init() {
        broker.display = Self.storedDisplay
        let checks = AppPreferences.bool(
            AppPreferences.checksConnectionsAtLaunch,
            default: AppPreferences.checksConnectionsAtLaunchDefault
        )
        if checks, !MecumApp.isCheckRun { settings.refresh() }
    }

    /// The virtual display Settings chose, the standard one until it chooses another.
    static var storedDisplay: SeatDisplay {
        let defaults = UserDefaults.standard
        let size     = defaults.string(forKey: AppPreferences.seatDisplaySize) ?? AppPreferences.seatDisplaySizeDefault
        let rate     = defaults.object(forKey: AppPreferences.seatRefreshRate) as? Int ?? AppPreferences.seatRefreshRateDefault
        return SeatDisplay(size: size, refreshRate: rate) ?? .standard
    }
}

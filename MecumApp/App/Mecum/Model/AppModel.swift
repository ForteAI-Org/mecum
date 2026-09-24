//
//  AppModel.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import SeatBroker

/// AppModel is what every window of the app shares: the seat broker the
/// workers' desktops go through, and the model settings.
///
/// Every connection is checked once as the app starts, in the background, so
/// the sidebar's badge and the workers' models are known before anyone opens
/// Connections, unless Settings > General turns it off. A check or test run
/// checks nothing: it would run the `codex` and `claude` command lines for real.
@MainActor
final class AppModel {

    let broker = SeatBroker(configuration: .init(allowUnvalidatedBuild: true))

    let settings = ModelSettingsStore()

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

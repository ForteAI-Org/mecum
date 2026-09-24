//
//  AppModel.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker

/// AppModel is what every window of the app shares: the seat broker the
/// workers' desktops go through, and the model settings.
///
/// Every connection is checked once as the app starts, in the background, so
/// the sidebar's badge and the workers' models are known before anyone opens
/// Connections. A check or test run checks nothing: it would run the `codex`
/// and `claude` command lines for real.
@MainActor
final class AppModel {

    let broker = SeatBroker(configuration: .init(allowUnvalidatedBuild: true))

    let settings = ModelSettingsStore()

    init() {
        if !MecumApp.isCheckRun { settings.refresh() }
    }
}

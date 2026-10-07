//
//  AppModel.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import LocalMCP
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

    /// External clients share the app's Seat broker, each with an engine state of its own, and learn
    /// into the same living memory as the workers: their calls are recorded with the `mcp` source and
    /// the profile as their stream, so they stay apart from the workers' in the archive.
    lazy var mcp = MCPConnectionsModel(
        directory: WorkspaceLaunch.directory.appendingPathComponent("MCP", isDirectory: true),
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mecum-bridge")
    ) { [broker] profile, activity in
        let desktop = BrokeredAutomationSession(
            broker: broker,
            workerID: UUID(),
            knowledgeDirectory: WorkspaceLaunch.directory.appendingPathComponent("Knowledge", isDirectory: true)
        )
        let session = ExternalMCPSession(
            profile: profile,
            session: desktop,
            perform: { body in
                var result = JSONValue.null
                try await desktop.turn { result = try await body() }
                return result
            },
            activity: activity
        )
        return MCPHostSession(router: session.router) { await session.close() }
    }

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

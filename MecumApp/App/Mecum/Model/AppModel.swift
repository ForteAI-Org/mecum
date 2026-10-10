//
//  AppModel.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import AutomationRuntime
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

    /// External clients share the app's Seat broker and the user's one living memory with the workers
    /// (`KnowledgeLocation`, G76): what a client learns the workers may reuse and the other way round, each
    /// call recorded with the `mcp` source and the profile as its stream, each task its own. A client's
    /// earlier private archive is unified into it once (`MemoryService.unify`), and kept where it was.
    lazy var mcp = MCPConnectionsModel(
        directory: WorkspaceLaunch.directory.appendingPathComponent("MCP", isDirectory: true),
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mecum-bridge")
    ) { [broker] profile, activity in
        let desktop = BrokeredAutomationSession(
            broker: broker,
            workerID: UUID(),
            knowledgeDirectory: KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory)
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

    /// The Knowledge directory an external client's profile had before G76, under the app's support
    /// directory: `MCP/Knowledge/<profile>`. Nothing writes there any more; the shared memory unifies it
    /// (`KnowledgeLocation.legacyProfiles`).
    nonisolated static func knowledgeDirectory(of profile: UUID, under support: URL) -> URL {
        support.appendingPathComponent("MCP/Knowledge/" + profile.uuidString, isDirectory: true)
    }

    init() {
        broker.display = Self.storedDisplay
        // The external clients' earlier private archives come into the shared memory when it first opens.
        MemoryService.unify(KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory),
                            with: KnowledgeLocation.legacyProfiles(under: WorkspaceLaunch.directory))
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

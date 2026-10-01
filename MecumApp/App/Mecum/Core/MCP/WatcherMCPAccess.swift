import Foundation
import LocalMCP

/// WatcherMCPAccess lends the app's watcher to at most one external session. A client cannot read
/// or stop a manual run or another client's run. Reconnection never inherits historical access.
@MainActor
final class WatcherMCPAccess {
    private let watcher: WatcherModel
    private var owner: UUID?
    private var runID: UUID?

    init(watcher: WatcherModel) { self.watcher = watcher }

    func call(_ name: String, arguments: JSONValue, owner requested: UUID) async throws -> JSONValue {
        let limit: Int
        if case .number(let number) = arguments["limit"] {
            guard number.isFinite, number.rounded() == number, (1...100).contains(number) else {
                throw MCPRequestFailure("limit must be an integer from 1 to 100.")
            }
            limit = Int(number)
        } else if arguments["limit"] == .null { limit = 20 }
        else { throw MCPRequestFailure("limit must be an integer.") }
        if name == "watch_start" {
            guard !watcher.isActive else { throw MCPRequestFailure("Watcher is already active. Its owner must stop it first.") }
            guard let app = arguments["app"].string, !app.isEmpty else { throw MCPRequestFailure("app is required.") }
            watcher.refreshEnvironment()
            let matches = watcher.applications.filter { $0.bundleID == app || $0.name == app }
            guard app == "*" || matches.count == 1 else { throw MCPRequestFailure("Use one exact running app name or bundle ID.") }
            watcher.selectedApplication = app == "*" ? nil : matches.first
            watcher.start()
            guard watcher.isActive else {
                if case .failed(let reason) = watcher.phase { throw MCPRequestFailure(reason) }
                throw MCPRequestFailure("Watcher could not start.")
            }
            owner = requested
            runID = watcher.runID
        } else {
            guard owner == requested, runID == watcher.runID else {
                throw MCPRequestFailure("This connection owns no watcher run. Start one explicitly with watch_start.")
            }
            if name == "watch_stop" { await watcher.stop() }
        }
        return MCPRouter.toolResult(.object([
            "run": .string(watcher.runID.uuidString), "status": .string(watcher.statusTitle),
            "detail": .string(watcher.detail), "total": .number(Double(watcher.totalEvents)),
            "retained": .number(Double(watcher.entries.count)),
            "events": try .encoding(Array(watcher.entries.prefix(limit))),
            "guidance": .string("Passive observations only. Before, after and AX are different evidence; causality is unverified.")
        ]))
    }

    func release(owner requested: UUID) async {
        guard owner == requested else { return }
        if runID == watcher.runID { await watcher.stop(); watcher.clear() }
        owner = nil
        runID = nil
    }
}

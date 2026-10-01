import BrowserCore
import Foundation
import LocalMCP
import Memory
import SeatBroker

/// MCPAppSessions composes external clients with the app's shared Seat, browser pool and watcher.
@MainActor
final class MCPAppSessions {
    var memory: (any LivingMemoryStoring)?
    private let broker: SeatBroker
    private let browser: BrowserSessionPool
    private let watcher: WatcherMCPAccess
    private let support: URL

    init(broker: SeatBroker, browser: BrowserSessionPool, watcher: WatcherModel, support: URL) {
        self.broker = broker
        self.browser = browser
        self.watcher = WatcherMCPAccess(watcher: watcher)
        self.support = support
    }

    func make(_ profile: MCPClientProfile, activity: @escaping @MainActor (String) -> Void,
              stalled: @escaping @MainActor (String) -> Void) -> MCPHostSession {
        let knowledge = profile.sharedMemory
            ? support.appendingPathComponent("Knowledge", isDirectory: true)
            : support.appendingPathComponent("MCP/Knowledge/" + profile.id.uuidString, isDirectory: true)
        let desktop = BrokeredAutomationSession(broker: broker, workerID: UUID(), knowledgeDirectory: knowledge,
                                               livingMemory: profile.sharedMemory ? memory : nil)
        let session = ExternalMCPSession(profile: profile, session: desktop, browser: browser.client(),
                                        memory: memory, watcher: watcher, perform: { body in
            var result = JSONValue.null
            try await desktop.turn { result = try await body() }
            return result
        }, activity: activity, stalled: stalled)
        return MCPHostSession(router: session.router) { await session.close() }
    }
}

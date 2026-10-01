import Foundation
import LocalMCP
import Observation

/// MCPClientConnection owns one enabled grant's host. Stopping closes admission before joining tools.
@MainActor
@Observable
final class MCPClientConnection: Identifiable {
    var profile: MCPClientProfile
    var id: UUID { profile.id }
    private(set) var isListening = false
    private(set) var connections = 0
    var activity = "No client connected"
    var failure: String?
    @ObservationIgnored private var host: LocalMCPHost?

    init(profile: MCPClientProfile) { self.profile = profile }

    func start(in directory: MCPConnectionDirectory,
               makeSession: @escaping @MainActor () -> MCPHostSession) async throws {
        guard host == nil else { return }
        failure = nil
        let host = LocalMCPHost(maximumConnections: 1, makeSession: makeSession)
        self.host = host
        host.onConnectionCount = { [weak self] in self?.connections = $0 }
        do {
            let endpoint = try await host.start()
            try directory.publish(endpoint, for: id)
            isListening = true
            activity = "Ready for a local client"
        } catch {
            await host.stopAndDrain()
            self.host = nil
            throw error
        }
    }

    func stopAccepting() {
        host?.stop()
        isListening = false
    }

    func stall(_ reason: String) {
        failure = reason + " Stop and enable this client after reviewing the failure."
        stopAccepting()
    }

    func stop(in directory: MCPConnectionDirectory) async throws {
        let host = self.host
        stopAccepting()
        var removalFailure: (any Error)?
        do { try directory.remove(id) } catch { removalFailure = error }
        await host?.stopAndDrain()
        self.host = nil
        connections = 0
        activity = "Stopped"
        if let removalFailure { throw removalFailure }
    }
}

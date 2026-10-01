import Foundation
import LocalMCP
import Observation

/// MCPConnectionsModel persists explicit grants and restores enabled clients on launch. One process
/// leases the directory. Mutations serialize; shutdown joins the current mutation before releasing it.
@MainActor
@Observable
final class MCPConnectionsModel {
    typealias SessionFactory = @MainActor (
        MCPClientProfile,
        @escaping @MainActor (String) -> Void,
        @escaping @MainActor (String) -> Void
    ) -> MCPHostSession
    private(set) var clients: [MCPClientConnection] = []
    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var hasDirectory = false
    private(set) var issue: String?
    @ObservationIgnored private let directory: MCPConnectionDirectory
    @ObservationIgnored private let store: MCPClientStore
    @ObservationIgnored private let executable: URL
    @ObservationIgnored private let makeSession: SessionFactory
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var didPrepare = false
    @ObservationIgnored private var isShuttingDown = false

    init(directory: URL, executable: URL, makeSession: @escaping SessionFactory) {
        self.directory = MCPConnectionDirectory(url: directory)
        self.store = MCPClientStore(directory: directory)
        self.executable = executable
        self.makeSession = makeSession
    }

    func prepare() async {
        guard !didPrepare, !isShuttingDown else { return }
        didPrepare = true
        mutate {
            try self.directory.acquire()
            self.hasDirectory = true
            self.clients = try self.store.load().map(MCPClientConnection.init)
            // Remove stale files before publishing fresh credentials, including disabled grants.
            for client in self.clients { try self.directory.remove(client.id) }
            self.isReady = true
            for client in self.clients where client.profile.enabled {
                do { try await self.start(client) }
                catch { client.failure = String(describing: error) }
            }
        }
        await waitForIdle()
    }

    func add(_ profile: MCPClientProfile) {
        guard isReady else { return }
        mutate {
            guard self.clients.count < 16, !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.name.count <= 80, !profile.enabled, !self.clients.contains(where: { $0.id == profile.id }) else {
                throw MCPRequestFailure("Use a name of 1–80 characters. At most 16 clients can be registered.")
            }
            try self.store.save(self.clients.map(\.profile) + [profile])
            self.clients.append(MCPClientConnection(profile: profile))
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard isReady else { return }
        mutate {
            guard let client = self.clients.first(where: { $0.id == id }) else { return }
            var profile = client.profile
            profile.enabled = enabled
            if !enabled {
                try await self.stop(client, remaining: self.clients.map { $0.id == id ? profile : $0.profile })
                client.profile = profile
            } else {
                try self.store.save(self.clients.map { $0.id == id ? profile : $0.profile })
                client.profile = profile
                client.failure = nil
                do { try await self.start(client) }
                catch { client.failure = String(describing: error); throw error }
            }
        }
    }

    func revoke(_ id: UUID) {
        guard isReady else { return }
        mutate {
            guard let client = self.clients.first(where: { $0.id == id }) else { return }
            try await self.stop(client, remaining: self.clients.filter { $0.id != id }.map(\.profile))
            self.clients.removeAll { $0.id == id }

        }
    }

    func configuration(for id: UUID) -> MCPClientConfiguration {
        MCPClientConfiguration(executable: executable, connection: directory.endpoint(for: id))
    }

    func waitForIdle() async { await operation?.value }

    func shutdown() async {
        isShuttingDown = true
        await waitForIdle()
        for client in clients { client.stopAccepting() }
        for client in clients {
            do { try await client.stop(in: directory) }
            catch { client.failure = String(describing: error); issue = String(describing: error) }
        }
        directory.release()
        hasDirectory = false
        isReady = false
    }

    /// Close admission even if saving the grant fails. Keep the row and explain the restart risk.
    private func stop(_ client: MCPClientConnection, remaining: [MCPClientProfile]) async throws {
        client.stopAccepting()
        client.failure = nil
        var failure: String?
        do { try store.save(remaining) }
        catch { failure = "Stopped, but the grant change could not be saved and may restore on restart: \(error)" }
        do { try await client.stop(in: directory) }
        catch {
            let cleanup = "Endpoint cleanup failed: \(error)"
            failure = failure.map { $0 + " " + cleanup } ?? cleanup
        }
        if let failure {
            client.failure = failure
            throw MCPRequestFailure(failure)
        }
    }

    private func start(_ client: MCPClientConnection) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MCPRequestFailure("The bundled mecum-bridge executable is missing. Rebuild or reinstall Mecum.")
        }
        let profile = client.profile
        try await client.start(in: directory) { [makeSession, weak client] in
            makeSession(profile, { [weak client] in client?.activity = $0 },
                        { [weak client] in client?.stall($0) })
        }
    }

    private func mutate(_ body: @escaping @MainActor () async throws -> Void) {
        guard !isBusy, !isShuttingDown else { return }
        isBusy = true
        issue = nil
        operation = Task {
            defer { isBusy = false }
            do { try await body() } catch { issue = String(describing: error) }
        }
    }
}

import Foundation
import Network

/// LocalMCPHost serves authenticated JSON frames on loopback only. Legacy chat hosts retain their
/// router between provider connections; external clients create an isolated session per connection.
/// stop closes admission and sockets; stopAndDrain also joins session cleanup before returning.
@MainActor
public final class LocalMCPHost {
    private let makeSession: @MainActor () -> MCPHostSession
    private let maximumConnections: Int
    private let token = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var channels: [UUID: MCPChannel] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    public var onConnectionCount: (@MainActor (Int) -> Void)?
    private var authenticated = Set<UUID>()

    public convenience init(router: MCPRouter) {
        self.init(maximumConnections: 16) {
            MCPHostSession(router: router, cancelsOnDisconnect: false)
        }
    }

    public init(
        maximumConnections: Int = 16,
        makeSession: @escaping @MainActor () -> MCPHostSession
    ) {
        self.maximumConnections = max(1, min(16, maximumConnections))
        self.makeSession = makeSession
    }

    public func start() async throws -> LocalConnection {
        guard listener == nil, tasks.isEmpty else { throw CocoaError(.fileWriteFileExists) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        do {
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        if let port = listener.port { continuation.resume(returning: port.rawValue) }
                        else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
            return LocalConnection(port: port, token: token)
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for channel in channels.values { channel.close() }
    }

    public func stopAndDrain() async {
        stop()
        for task in tasks.values { await task.value }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, channels.count < maximumConnections else { connection.cancel(); return }
        let id = UUID()
        let channel = MCPChannel(connection)
        channels[id] = channel
        tasks[id] = Task { [self] in
            await serve(channel, id: id)
            tasks.removeValue(forKey: id)
        }
    }

    private func serve(_ channel: MCPChannel, id: UUID) async {
        var peer: MCPPeer?
        let authenticationDeadline = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if !authenticated.contains(id) { channel.close() }
        }
        defer {
            authenticationDeadline.cancel()
            authenticated.remove(id)
            channels.removeValue(forKey: id)
            channel.close()
            onConnectionCount?(authenticated.count)
        }
        do {
            try await channel.start()
            while let envelope = try await channel.read() {
                guard envelope["token"].string == token else { break }
                if peer == nil {
                    peer = MCPPeer(channel: channel, session: makeSession())
                    authenticated.insert(id)
                    authenticationDeadline.cancel()
                    onConnectionCount?(authenticated.count)
                }
                try peer?.receive(envelope["message"])
            }
        } catch {
            // EOF, authentication rejection and socket failure all join the same session cleanup.
        }
        await peer?.finish()
    }
}

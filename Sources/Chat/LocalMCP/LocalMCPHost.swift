import Foundation
import Network

/// LocalMCPHost bridges authenticated loopback JSON frames to MCPRouter. The host, not provider children,
/// owns its lifetime. Provider reconnections preserve the application session; stop closes every connection.
@MainActor
public final class LocalMCPHost {
    private let router: MCPRouter
    private let token = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var channels: [UUID: MCPChannel] = [:]

    public init(router: MCPRouter) { self.router = router }

    public func start() async throws -> LocalConnection {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in await self?.serve(connection) }
        }
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
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        return LocalConnection(port: port, token: token)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for channel in channels.values { channel.close() }
        channels.removeAll()
    }

    private func serve(_ connection: NWConnection) async {
        guard listener != nil else { connection.cancel(); return }
        let id = UUID()
        let channel = MCPChannel(connection)
        channels[id] = channel
        defer { channels.removeValue(forKey: id); channel.close() }
        do {
            try await channel.start()
            while let envelope = try await channel.read() {
                guard envelope["token"].string == token else { return }
                let reply = await router.handle(envelope["message"])
                try await channel.write(reply ?? .null)
            }
        } catch {
            // A disconnected provider is expected between turns. The host retains its Seat until close.
        }
    }
}

import Foundation
import Network

/// MCPStdioBridge forwards standard MCP JSONL to an existing host. It never captures, launches Mecum,
/// reconnects or replays a request. Full-duplex forwarding delivers cancellation while a tool runs.
@MainActor
public enum MCPStdioBridge {
    public static func run(connectionFile: URL) async throws {
        let endpoint: LocalConnection
        do { endpoint = try JSONDecoder().decode(LocalConnection.self, from: Data(contentsOf: connectionFile)) }
        catch { throw MCPBridgeFailure.unavailable }
        guard !endpoint.token.isEmpty, let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw MCPBridgeFailure.unavailable
        }
        let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        do { try await channel.start() } catch { throw MCPBridgeFailure.unavailable }
        let input = MCPInputLines()
        defer { input.stop(); channel.close() }
        let exchange = Exchange()
        try await withTaskCancellationHandler {
            let writer = Task { @MainActor in
                do {
                    for try await request in input.values {
                        try await channel.write(.object(["token": .string(endpoint.token), "message": request]))
                    }
                    exchange.inputEnded = true
                } catch { exchange.failure = error }
                // EOF means the client has left. Close now so the host cancels any pending action.
                channel.close()
            }
            var disconnected = false
            do {
                while let response = try await channel.read() {
                    if response != .null {
                        var data = try JSONEncoder().encode(response)
                        data.append(10)
                        try FileHandle.standardOutput.write(contentsOf: data)
                    }
                }
                disconnected = !exchange.inputEnded
            } catch { disconnected = !exchange.inputEnded }
            input.stop()
            channel.close()
            await writer.value
            try Task.checkCancellation()
            if let failure = exchange.failure { throw failure }
            if disconnected { throw MCPBridgeFailure.disconnected }
        } onCancel: {
            input.stop()
            Task { @MainActor in channel.close() }
        }
    }

    @MainActor
    private final class Exchange {
        var failure: (any Error)?
        var inputEnded = false
    }
}

public enum MCPBridgeFailure: Error, CustomStringConvertible {
    case unavailable, disconnected

    public var description: String {
        switch self {
        case .unavailable:
            "Mecum is unavailable. Open Mecum and enable this client in MCP Connections; copy its current configuration if needed."
        case .disconnected:
            "Mecum disconnected or refused this connection. Check MCP Connections. A tool may have acted; observe before retrying."
        }
    }
}

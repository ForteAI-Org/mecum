import Foundation
import Network

/// MCPStdioBridge forwards standard MCP JSONL to the existing host and never starts capture or a Seat.
@MainActor
public enum MCPStdioBridge {
    public static func run(connectionFile: URL) async throws {
        let endpoint = try JSONDecoder().decode(LocalConnection.self, from: Data(contentsOf: connectionFile))
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw CocoaError(.fileReadCorruptFile) }
        let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        try await channel.start()
        defer { channel.close() }
        while let line = await Task.detached(operation: { readLine() }).value {
            if line.isEmpty { continue }
            let request = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            try await channel.write(.object(["token": .string(endpoint.token), "message": request]))
            guard let response = try await channel.read() else { throw CocoaError(.fileReadUnknown) }
            if response != .null {
                var data = try JSONEncoder().encode(response)
                data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            }
        }
    }
}

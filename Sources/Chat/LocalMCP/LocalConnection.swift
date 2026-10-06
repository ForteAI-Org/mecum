import Foundation
import Network

/// LocalConnection is an ephemeral loopback endpoint. Its credential file is private to the chat owner.
public struct LocalConnection: Codable, Sendable {
    public let port: UInt16
    public let token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }
}

/// MCPChannel owns a newline-framed connection. Reads are bounded to 8 MB; only one reader may borrow it.
@MainActor
final class MCPChannel {
    let connection: NWConnection
    private var buffer = Data()
    private var hasStarted = false
    private var isClosed = false
    private var startContinuation: CheckedContinuation<Void, any Error>?

    init(_ connection: NWConnection) { self.connection = connection }

    func start() async throws {
        guard !isClosed else { throw CancellationError() }
        guard !hasStarted else { throw CocoaError(.fileReadUnknown) }
        hasStarted = true
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let pending = self.startContinuation else { return }
                    switch state {
                    case .ready:
                        self.startContinuation = nil
                        self.connection.stateUpdateHandler = nil
                        pending.resume()
                    case .failed(let error):
                        self.startContinuation = nil
                        self.connection.stateUpdateHandler = nil
                        pending.resume(throwing: error)
                    case .cancelled:
                        self.startContinuation = nil
                        self.connection.stateUpdateHandler = nil
                        pending.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func read() async throws -> JSONValue? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return try JSONDecoder().decode(JSONValue.self, from: line)
            }
            let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if complete && (data?.isEmpty ?? true) { continuation.resume(returning: nil) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            guard let chunk else {
                guard buffer.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                return nil
            }
            buffer.append(chunk)
            guard buffer.count <= 8 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        }
    }

    func write(_ value: JSONValue) async throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func close() {
        isClosed = true
        connection.cancel()
        // A stop can arrive before Network starts delivering state callbacks.
        let pending = startContinuation
        startContinuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

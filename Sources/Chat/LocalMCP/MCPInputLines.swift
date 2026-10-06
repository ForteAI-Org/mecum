import Darwin
import Foundation

/// MCPInputLines borrows stdin (or a test pipe) without a blocking read task. One serial queue owns
/// the decoder buffer. Dispatch cancellation and AsyncStream continuation operations are thread-safe.
/// Requests are limited to 1 MiB and sixteen queued messages; overflow terminates explicitly.
nonisolated final class MCPInputLines: @unchecked Sendable {
    let values: AsyncThrowingStream<JSONValue, any Error>
    private let source: any DispatchSourceRead
    private let continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation
    private var buffer = Data()
    private let descriptor: Int32

    init(descriptor: Int32 = STDIN_FILENO) {
        self.descriptor = descriptor
        let pair = AsyncThrowingStream<JSONValue, any Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        values = pair.stream
        continuation = pair.continuation
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                               queue: DispatchQueue(label: "dev.forte.mecum.mcp.stdin"))
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { pair.continuation.finish() }
        pair.continuation.onTermination = { [weak self] _ in self?.stop() }
        source.resume()
    }

    deinit { source.cancel() }
    func stop() { source.cancel() }

    private func receive() {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        do {
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 {
                guard buffer.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                continuation.finish()
                stop()
                return
            }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= 1_048_576 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                let value = try JSONDecoder().decode(JSONValue.self, from: line)
                switch continuation.yield(value) {
                case .enqueued: break
                case .dropped: throw CocoaError(.fileReadTooLarge)
                case .terminated: stop(); return
                @unknown default: stop(); return
                }
            }
            guard buffer.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        } catch {
            continuation.finish(throwing: error)
            stop()
        }
    }
}

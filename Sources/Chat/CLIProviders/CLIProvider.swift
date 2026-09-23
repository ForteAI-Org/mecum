import ChatCore
import Darwin
import Foundation

/// CLIProvider owns one child process per turn. It streams both pipes concurrently, never invokes a
/// shell, and never retries a failed turn. Main-actor ownership serializes cancellation and process state.
@MainActor
public final class CLIProvider {
    private var process: Process?
    private var cancelled = false

    public init() {}

    /// Waits until the child has exited and both output pipes have been drained.
    public func waitUntilStopped() async {
        while process != nil { try? await Task.sleep(for: .milliseconds(25)) }
    }

    public func cancel() {
        cancelled = true
        guard let process, process.isRunning else { return }
        process.interrupt()
        Task { [weak self, weak process] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let process, self.process === process, process.isRunning else { return }
            process.terminate()
            try? await Task.sleep(for: .seconds(2))
            if self.process === process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// `onStart` receives the child's identity once it is spawned, before any event, so a caller
    /// can record it and a later launch can end a child the app did not outlive (§18.4).
    public func run(
        _ turn: ProviderTurn,
        executable: URL,
        onStart: @MainActor (ChildProcessIdentity) -> Void = { _ in },
        onEvent: @escaping @MainActor (ProviderEvent) throws -> Void
    ) async throws {
        guard process == nil else { throw failure("A provider turn is already running.") }
        let invocation = try ProviderInvocation(turn)
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        child.executableURL = executable
        child.arguments = invocation.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: turn.workingDirectory)
        child.standardOutput = output
        child.standardError = errors
        child.standardInput = input
        var environment = turn.environment ?? ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        child.environment = environment
        cancelled = false
        try child.run()
        process = child
        defer { process = nil }
        // A child that has already exited has no identity to record, and nothing to end later.
        if let identity = ChildProcessIdentity(running: child.processIdentifier) { onStart(identity) }

        let stdout = Self.chunks(output.fileHandleForReading)
        let stderr = Self.chunks(errors.fileHandleForReading)
        let errorTask = Task { () throws -> String in
            var tail = Data()
            for try await chunk in stderr {
                tail.append(chunk)
                if tail.count > 16_384 { tail = tail.suffix(16_384) }
            }
            return String(decoding: tail, as: UTF8.self)
        }
        let inputTask = Task.detached {
            defer { try? input.fileHandleForWriting.close() }
            try input.fileHandleForWriting.write(contentsOf: Data(invocation.standardInput.utf8))
        }

        var decoder = ProviderEventDecoder(provider: turn.provider)
        var pending = Data()
        var completed = false
        var providerFailure: String?
        do {
            for try await chunk in stdout {
                pending.append(chunk)
                guard pending.count <= 8 * 1_024 * 1_024 else { throw failure("Provider event exceeded 8 MB.") }
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    for event in try decoder.decode(line) {
                        if case .completed = event { completed = true }
                        if case .failure(let message) = event { providerFailure = message }
                        try onEvent(event)
                    }
                }
            }
            if !pending.isEmpty {
                for event in try decoder.decode(pending) {
                    if case .completed = event { completed = true }
                    if case .failure(let message) = event { providerFailure = message }
                    try onEvent(event)
                }
            }
            try await inputTask.value
            while child.isRunning { try await Task.sleep(for: .milliseconds(25)) }
            let diagnostics = try await errorTask.value
            if cancelled { throw CancellationError() }
            if let providerFailure { throw failure(providerFailure) }
            guard child.terminationStatus == 0, completed else {
                throw failure("Provider exited with status \(child.terminationStatus) without a successful turn. "
                              + String(diagnostics.suffix(4_000)))
            }
        } catch {
            cancel()
            while child.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
            _ = await inputTask.result
            _ = await errorTask.result
            if cancelled && error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private nonisolated static func chunks(_ handle: FileHandle) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                defer { try? handle.close() }
                do {
                    while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "MecumProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

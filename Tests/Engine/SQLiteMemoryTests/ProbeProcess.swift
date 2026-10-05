//
//  ProbeProcess.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Synchronization
import Testing

/// ProbeProcess is one `memory-probe` in a process of its own: a second real holder of the file,
/// with its own connections and locks, driven by lines on its input and observed by the lines it
/// answers. Every wait in a test is on one of those lines, with a deadline, never on a sleep; a
/// crash is a real `SIGKILL`; and `end` is called in every path so no helper outlives its test.
/// One test task uses one instance, in sequence; the type is not meant to be shared.
///
/// The helper's output is read by a thread of this instance's own with `read(2)`, not through
/// `FileHandle.bytes`: Foundation serves every `AsyncBytes` from one serial queue, so with two
/// helpers the blocking read of one held back the lines, and the end of file, of the other.
final class ProbeProcess {

    /// The helper's binary, built into the products directory beside this test bundle (`swift test`
    /// builds it; so does `swift build --product memory-probe`); `MECUM_MEMORY_PROBE` names another.
    /// Nil when neither is an executable file. The runner's own `Bundle.main` is in the toolchain,
    /// so the search starts from the bundle that holds these tests.
    static let executable: URL? = {
        if let named = ProcessInfo.processInfo.environment["MECUM_MEMORY_PROBE"], !named.isEmpty {
            return URL(fileURLWithPath: named)
        }
        var candidates: [URL] = []
        var directory = Bundle(for: ProbeProcess.self).bundleURL
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent("memory-probe"))
            directory = directory.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    struct Timeout: Error {
        let waitingFor: String
    }

    let process = Process()

    private let input    = Pipe()
    private let output   = Pipe()
    private let lines    : AsyncStream<String>
    private let timedOut = Flag()

    /// A flag a watchdog task raises from outside the test's task.
    private final class Flag: Sendable {

        private let value = Mutex(false)

        func raise() { value.withLock { $0 = true } }

        var isRaised: Bool { value.withLock { $0 } }
    }

    /// Starts the helper, or records why it could not and throws. A missing binary is a failed
    /// prerequisite, not a passed test.
    init() throws {
        guard let executable = Self.executable else {
            Issue.record("memory-probe is not built beside the test bundle (\(Bundle(for: ProbeProcess.self).bundleURL.path)); run swift build --product memory-probe")
            throw Timeout(waitingFor: "memory-probe")
        }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        lines = stream
        process.executableURL  = executable
        process.standardInput  = input
        process.standardOutput = output
        process.standardError  = FileHandle.standardError
        let descriptor = output.fileHandleForReading.fileDescriptor
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var carry : [UInt8] = []
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                carry.append(contentsOf: buffer[0..<count])
                while let newline = carry.firstIndex(of: 10) {
                    continuation.yield(String(decoding: carry[..<newline], as: UTF8.self))
                    carry.removeSubrange(...newline)
                }
            }
            if !carry.isEmpty { continuation.yield(String(decoding: carry, as: UTF8.self)) }
            continuation.finish()
        }
        reader.name = "memory-probe output"
        try process.run()
        reader.start()
    }

    /// Sends one line. A helper that already ended answers nothing, which the next `receive` sees.
    func send(_ line: String) {
        guard process.isRunning else { return }
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    /// The next line the helper answers, or nil once its output ended (it exited or was killed).
    /// Throws `Timeout` when nothing arrives within the deadline: the helper is then killed, since
    /// a helper that does not answer is of no further use to the test.
    func receive(timeout: Duration = .seconds(20), waitingFor: String = "a line") async throws -> String? {
        let pid      = process.processIdentifier
        let timedOut = self.timedOut
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            timedOut.raise()
            Darwin.kill(pid, SIGKILL)
        }
        defer { watchdog.cancel() }
        // One iterator per call: the stream's buffer is shared, and only this task ever reads it.
        var iterator = lines.makeAsyncIterator()
        let line     = await iterator.next()
        if timedOut.isRaised { throw Timeout(waitingFor: waitingFor) }
        return line
    }

    /// Sends a line and answers the next one; a helper that answers nothing is a recorded issue.
    @discardableResult
    func ask(_ line: String, timeout: Duration = .seconds(20)) async throws -> String {
        send(line)
        return try await expect(line, timeout: timeout)
    }

    /// The next line, with a recorded issue when the helper ended instead of answering.
    func expect(_ waitingFor: String, timeout: Duration = .seconds(20)) async throws -> String {
        guard let line = try await receive(timeout: timeout, waitingFor: waitingFor) else {
            Issue.record("the helper ended instead of answering \(waitingFor)")
            throw Timeout(waitingFor: waitingFor)
        }
        return line
    }

    /// Waits for the line that starts with the prefix, skipping wait-event lines, up to the deadline.
    func expect(prefix: String, timeout: Duration = .seconds(20)) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw Timeout(waitingFor: prefix) }
            let line = try await expect(prefix, timeout: remaining)
            if line.hasPrefix(prefix) { return line }
            guard line.hasPrefix("wait ") else {
                Issue.record("expected a line starting with '\(prefix)', got '\(line)'")
                throw Timeout(waitingFor: prefix)
            }
        }
    }

    /// Ends the helper the way a crash does: no chance to flush, roll back or answer.
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    /// Waits for the helper to exit and answers how it ended, or nil past the deadline.
    func exit(timeout: Duration = .seconds(20)) async throws -> (status: Int32, reason: Process.TerminationReason)? {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            guard ContinuousClock.now < deadline else { return nil }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (process.terminationStatus, process.terminationReason)
    }

    /// Kills the helper if it still runs and waits, up to a deadline, until Foundation has seen it
    /// end. Called in every path of a test; the reader thread ends with the helper's output. It
    /// polls `isRunning` as `exit` does instead of calling `waitUntilExit`, which runs the calling
    /// thread's run loop and, called from a test's task after a kill, once never returned and held
    /// the whole runner; a helper that outlives the deadline is a recorded issue, not a hang.
    func end() {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            let deadline = ContinuousClock.now + .seconds(10)
            while process.isRunning, ContinuousClock.now < deadline { usleep(1_000) }
            if process.isRunning { Issue.record("memory-probe \(process.processIdentifier) still runs 10 s after its kill") }
        }
        try? input.fileHandleForWriting.close()
    }
}

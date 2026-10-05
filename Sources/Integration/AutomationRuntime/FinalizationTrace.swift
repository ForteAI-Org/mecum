//
//  FinalizationTrace.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 05/10/2026.
//

import Darwin
import Foundation
import Memory
import SQLiteMemory
import Synchronization

/// FinalizationTrace is an opt-in diagnostic of the memory's budget after a stop, for a live proof run
/// from outside the process: it says when a finalization of an owner was really waiting for the
/// archive's lock, when that owner stopped and how its finalizations ended. It is off unless the process
/// starts with `MECUM_MEMORY_FINALIZATION_TRACE` naming a file; then it appends one line per step to that
/// file and nothing else. It reads what the service and the store decide and changes none of it: not the
/// budget, not the stop, not what is written or how a wait is retried. No line carries a value of the
/// agent's: only the process, numbers it makes up for owners and finalizations, the store's phase and
/// the clocks.
///
/// A line is `<step> pid=<pid> owner=<n> [finalization=<n>] [detail…] uptime_ns=<ns> continuous_ns=<ns>`,
/// the two readings being `CLOCK_UPTIME_RAW` and `CLOCK_MONOTONIC_RAW`: the budget runs on
/// `ContinuousClock`, which goes on through a sleep as the second does, and a sleep shows as the two
/// drifting apart. Another process reading the same clocks can place its own instants among the lines.
///
/// Steps: `offered` (a finalization handed to an owner), `waiting` (its write found the lock busy, once
/// per finalization, with the store's phase), `cycle` (a whole lock budget of its write ran out and
/// another began), `stopped` (the owner's first stop, with how many finalizations were waiting on it),
/// `cut` (the owner's deadline cut one), `ended` (one ended: `written`, `gap` or `failed`) and `refused`
/// (one offered once the owner's time was spent: a gap at once, no body run).
nonisolated enum FinalizationTrace {

    /// One finalization as the trace names it, bound in its detached work so the store's waits find it.
    struct Mark: Sendable {
        let owner: Int
        let finalization: Int
    }

    @TaskLocal static var current: Mark?

    /// The file the lines go to and the numbering, nil while the trace is off.
    private final class Sink: Sendable {
        private let descriptor: Int32
        private let state = Mutex(Numbering())

        private struct Numbering {
            var owners = 0
            var finalizations = 0
            var waited: Set<Int> = []
        }

        init?(path: String) {
            let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return nil }
            self.descriptor = descriptor
        }

        deinit { Darwin.close(descriptor) }

        func nextOwner() -> Int {
            state.withLock { numbering in
                numbering.owners += 1
                return numbering.owners
            }
        }

        func nextFinalization() -> Int {
            state.withLock { numbering in
                numbering.finalizations += 1
                return numbering.finalizations
            }
        }

        /// True the first time a finalization's write is seen waiting.
        func firstWait(_ finalization: Int) -> Bool {
            state.withLock { $0.waited.insert(finalization).inserted }
        }

        /// One line, written whole with one `write` on a descriptor opened for appending.
        func line(_ step: String, owner: Int, finalization: Int? = nil, _ detail: String = "") {
            let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), continuous = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            var text = "\(step) pid=\(getpid()) owner=\(owner)"
            if let finalization { text += " finalization=\(finalization)" }
            if !detail.isEmpty { text += " \(detail)" }
            text += " uptime_ns=\(uptime) continuous_ns=\(continuous)\n"
            _ = text.utf8CString.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count - 1) }
        }
    }

    private static let sink = Mutex<Sink?>(
        ProcessInfo.processInfo.environment["MECUM_MEMORY_FINALIZATION_TRACE"].flatMap { Sink(path: $0) }
    )

    private static var active: Sink? { sink.withLock { $0 } }

    /// Sends the lines to `path` from now on, or turns the trace off with nil. For the module's tests.
    static func record(to path: String?) {
        let next = path.flatMap { Sink(path: $0) }
        sink.withLock { $0 = next }
    }

    /// A number for an owner made now, nil while the trace is off; an owner made before the trace was
    /// turned on is owner 0.
    static func numberOwner() -> Int? {
        active?.nextOwner()
    }

    /// The store's waits, followed for the finalizations among them: only while the trace is on.
    static func follow(_ store: SQLiteMemoryStore) async {
        guard active != nil else { return }
        await store.observeWaits { event in FinalizationTrace.waited(event) }
    }

    /// A finalization handed to `scope`: its mark, nil while the trace is off.
    static func offered(_ scope: MemoryFinalizationScope) -> Mark? {
        guard let sink = active else { return nil }
        let mark = Mark(owner: scope.traceNumber ?? 0, finalization: sink.nextFinalization())
        sink.line("offered", owner: mark.owner, finalization: mark.finalization)
        return mark
    }

    /// Runs the finalization's work with its mark bound, so the store's waits inside it are its own.
    static func run<T: Sendable>(_ mark: Mark?, _ work: () async throws -> T) async throws -> T {
        guard let mark else { return try await work() }
        return try await $current.withValue(mark) { try await work() }
    }

    /// Awaits the finalization's end and says how it ended.
    static func ending<T: Sendable>(_ mark: Mark?, _ work: () async throws -> T) async throws -> T {
        guard let mark, let sink = active else { return try await work() }
        do {
            let value = try await work()
            sink.line("ended", owner: mark.owner, finalization: mark.finalization, "outcome=written")
            return value
        } catch {
            sink.line("ended", owner: mark.owner, finalization: mark.finalization,
                      "outcome=\(MemoryService.isCancellation(error) ? "gap" : "failed")")
            throw error
        }
    }

    static func cut(_ mark: Mark?) {
        guard let mark, let sink = active else { return }
        sink.line("cut", owner: mark.owner, finalization: mark.finalization)
    }

    static func stopped(_ scope: MemoryFinalizationScope, waiting: Int) {
        guard let sink = active else { return }
        sink.line("stopped", owner: scope.traceNumber ?? 0, "waiting=\(waiting)")
    }

    static func refused(_ scope: MemoryFinalizationScope) {
        guard let sink = active else { return }
        sink.line("refused", owner: scope.traceNumber ?? 0)
    }

    /// The store's wait, on the waiting write's own task: a finalization's when its mark is bound there.
    private static func waited(_ event: SQLiteMemoryStore.WaitEvent) {
        guard let mark = current, let sink = active else { return }
        switch event {
            case .pausing(let phase, let attempt):
                guard sink.firstWait(mark.finalization) else { return }
                sink.line("waiting", owner: mark.owner, finalization: mark.finalization, "phase=\(phase.rawValue) attempt=\(attempt)")
            case .cycleExhausted(let phase, let attempts, _):
                sink.line("cycle", owner: mark.owner, finalization: mark.finalization, "phase=\(phase.rawValue) attempts=\(attempts)")
            case .yielding:
                return
        }
    }
}

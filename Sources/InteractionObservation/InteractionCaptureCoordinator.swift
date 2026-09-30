import Foundation
import InteractionListener
import PerceptionCore

/// InteractionCaptureCoordinator serializes scene reads and gives event diagnostics priority.
/// Shared tasks are joined before returning; cancellation never abandons an underlying capture.
@MainActor
final class InteractionCaptureCoordinator {
    enum Priority { case ambient, event }
    private struct Flight {
        let id: UUID
        let window: InteractionWindow
        let revision: UInt64
        let task: Task<InteractionSample, any Error>
    }
    private var flight: Flight?
    private var eventWaiters = 0
    private let now: () -> Double

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func read(
        window: InteractionWindow,
        revision: UInt64,
        priority: Priority,
        isCurrent: () -> Bool,
        load: @escaping @MainActor () async throws -> SceneSnapshot
    ) async throws -> InteractionSample? {
        try Task.checkCancellation()
        guard isCurrent() else { return nil }
        if priority == .ambient, flight != nil || eventWaiters > 0 { return nil }
        if priority == .event { eventWaiters += 1 }
        defer { if priority == .event { eventWaiters -= 1 } }
        while let running = flight {
            let result = await running.task.result
            if flight?.id == running.id { flight = nil }
            try Task.checkCancellation()
            guard isCurrent() else { return nil }
            if running.window == window, running.revision == revision {
                return try result.get()
            }
            // The original consumer reports failures of an unrelated acquisition.
            // This request still needs its own window and input revision.
        }
        try Task.checkCancellation()
        guard isCurrent() else { return nil }
        let started = now()
        let task = Task { [now] in
            let scene = try await load()
            return InteractionSample(window: window, scene: scene, revision: revision,
                                     startedAt: started, completedAt: now())
        }
        let current = Flight(id: UUID(), window: window, revision: revision, task: task)
        flight = current
        defer { if flight?.id == current.id { flight = nil } }
        let sample = try await task.value
        try Task.checkCancellation()
        return isCurrent() ? sample : nil
    }
}

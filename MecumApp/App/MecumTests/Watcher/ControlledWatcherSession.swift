import Foundation
import InteractionObservation
@testable import Mecum

/// ControlledWatcherSession holds teardown open to exercise cancellation and restart ordering.
@MainActor
final class ControlledWatcherSession: WatcherSession {
    var report: (@MainActor (InteractionReport) -> Void)?
    var status: (@MainActor (InteractionObserverStatus) -> Void)?
    var holdsCleanup = false
    private(set) var didStart = false
    private(set) var didRequestStop = false
    private(set) var didRelease = false
    private var completion: CheckedContinuation<Void, any Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        report: @escaping @MainActor (InteractionReport) -> Void,
        status: @escaping @MainActor (InteractionObserverStatus) -> Void
    ) async throws {
        self.report = report
        self.status = status
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            didStart = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitForStart() async {
        if !didStart { await withCheckedContinuation { startWaiters.append($0) } }
    }

    func waitForStopRequest() async {
        if !didRequestStop { await withCheckedContinuation { stopWaiters.append($0) } }
    }

    func stop() async {
        didRequestStop = true
        stopWaiters.forEach { $0.resume() }
        stopWaiters.removeAll()
        if holdsCleanup { await withCheckedContinuation { cleanupWaiters.append($0) } }
        didRelease = true
        completion?.resume(throwing: CancellationError())
        completion = nil
    }

    func releaseCleanup() {
        holdsCleanup = false
        cleanupWaiters.forEach { $0.resume() }
        cleanupWaiters.removeAll()
    }

    func fail(_ error: any Error) {
        completion?.resume(throwing: error)
        completion = nil
    }
}

//
//  CaptureFrameworkCoordinatorTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Foundation
@testable import SeatCapture
import Synchronization
import Testing

nonisolated private final class FrameworkCallbacks: @unchecked Sendable {

    typealias Completion = @Sendable (Result<Void, CaptureFailure>) -> Void

    private let callbacks = Mutex<[Completion]>([])

    var count: Int { callbacks.withLock { $0.count } }

    func append(_ callback: @escaping Completion) {
        callbacks.withLock { $0.append(callback) }
    }

    func completeAll(_ result: Result<Void, CaptureFailure> = .success(())) {
        let pending = callbacks.withLock { callbacks -> [Completion] in
            defer { callbacks.removeAll() }
            return callbacks
        }
        for callback in pending { callback(result) }
    }
}

@Suite("The bounded ScreenCaptureKit callback coordinator")
struct CaptureFrameworkCoordinatorTests {

    @Test("caller timeout does not release a framework slot")
    func timeoutRetainsFrameworkSlots() async {
        let coordinator = CaptureFrameworkCoordinator()
        let callbacks = FrameworkCallbacks()
        let requests = (0..<3).map { _ in
            Task {
                let _: Void = try await coordinator.value(
                    key     : nil,
                    step    : .still,
                    deadline: CaptureDeadline(timeout: .milliseconds(500))
                ) { completion in
                    callbacks.append(completion)
                }
            }
        }

        #expect(await waitUntil { callbacks.count == 3 })
        for request in requests {
            let error = await capturedError(from: request)
            #expect(error as? CaptureFailure == .timedOut(.still))
        }
        #expect(coordinator.metrics.pendingFrameworkCalls == 3)
        #expect(coordinator.metrics.retainedWaiters == 0)

        await #expect(throws: CaptureFailure.frameworkCallLimitReached(.still)) {
            let _: Void = try await coordinator.value(
                key     : nil,
                step    : .still,
                allowsQueue: false,
                deadline: CaptureDeadline(timeout: .seconds(1))
            ) { _ in
                Issue.record("an ordinary fourth call must not reach the framework")
            }
        }

        callbacks.completeAll()
        #expect(await waitUntil { coordinator.metrics.pendingFrameworkCalls == 0 })
    }

    @Test("a late join does not extend the first job deadline")
    func coalescedDeadlineIsNotExtended() async {
        let coordinator = CaptureFrameworkCoordinator()
        let callbacks = FrameworkCallbacks()
        let first = Task {
            let _: Void = try await coordinator.value(
                key     : .shareableContent,
                step    : .shareableContent,
                deadline: CaptureDeadline(timeout: .milliseconds(500))
            ) { completion in
                callbacks.append(completion)
            }
        }

        #expect(await waitUntil { callbacks.count == 1 })
        let lateJoin = Task {
            let _: Void = try await coordinator.value(
                key     : .shareableContent,
                step    : .shareableContent,
                deadline: CaptureDeadline(timeout: .seconds(5))
            ) { _ in
                Issue.record("compatible work must use the existing callback")
            }
        }

        #expect(await capturedError(from: first) as? CaptureFailure
            == .timedOut(.shareableContent))
        #expect(await capturedError(from: lateJoin) as? CaptureFailure
            == .timedOut(.shareableContent))
        #expect(coordinator.metrics.admittedFrameworkCalls == 1)
        #expect(coordinator.metrics.coalescedRequests == 1)
        #expect(coordinator.metrics.pendingFrameworkCalls == 1)

        callbacks.completeAll()
        #expect(await waitUntil { coordinator.metrics.pendingFrameworkCalls == 0 })
        #expect(coordinator.metrics.lateResults == 1)
        #expect(coordinator.metrics.discardedResults == 1)
    }

    @Test("cancelling one coalesced waiter leaves the callback and peer alive")
    func cancellationIsPerWaiter() async {
        let coordinator = CaptureFrameworkCoordinator()
        let callbacks = FrameworkCallbacks()
        let first = Task {
            let _: Void = try await coordinator.value(
                key     : .shareableContent,
                step    : .shareableContent,
                deadline: CaptureDeadline(timeout: .seconds(5))
            ) { completion in
                callbacks.append(completion)
            }
        }

        #expect(await waitUntil { callbacks.count == 1 })
        let peer = Task {
            let _: Void = try await coordinator.value(
                key     : .shareableContent,
                step    : .shareableContent,
                deadline: CaptureDeadline(timeout: .seconds(5))
            ) { _ in
                Issue.record("the peer must coalesce with the first request")
            }
        }
        #expect(await waitUntil { coordinator.metrics.retainedWaiters == 2 })

        first.cancel()
        #expect(await capturedError(from: first) is CancellationError)
        #expect(coordinator.metrics.pendingFrameworkCalls == 1)
        #expect(coordinator.metrics.retainedWaiters == 1)

        callbacks.completeAll()
        do {
            try await peer.value
        } catch {
            Issue.record("the valid peer failed: \(error)")
        }
        #expect(coordinator.metrics.completedFrameworkCalls == 1)
    }

    @Test("ordinary pressure preserves one framework slot for cleanup")
    func cleanupCapacityIsReserved() async {
        let coordinator = CaptureFrameworkCoordinator()
        let ordinaryCallbacks = FrameworkCallbacks()
        let cleanupCallbacks = FrameworkCallbacks()
        let ordinary = (0..<3).map { _ in
            Task {
                let _: Void = try await coordinator.value(
                    key     : nil,
                    step    : .still,
                    deadline: CaptureDeadline(timeout: .seconds(5))
                ) { completion in
                    ordinaryCallbacks.append(completion)
                }
            }
        }

        #expect(await waitUntil { ordinaryCallbacks.count == 3 })
        await #expect(throws: CaptureFailure.frameworkCallLimitReached(.still)) {
            let _: Void = try await coordinator.value(
                key     : nil,
                step    : .still,
                allowsQueue: false,
                deadline: CaptureDeadline(timeout: .seconds(1))
            ) { _ in
                Issue.record("ordinary work must not consume cleanup reserve")
            }
        }

        let cleanup = Task {
            let _: Void = try await coordinator.value(
                key      : nil,
                step     : .streamStop,
                callClass: .cleanup,
                deadline : CaptureDeadline(timeout: .seconds(5))
            ) { completion in
                cleanupCallbacks.append(completion)
            }
        }
        #expect(await waitUntil { cleanupCallbacks.count == 1 })
        #expect(coordinator.metrics.pendingFrameworkCalls == 4)

        ordinaryCallbacks.completeAll()
        cleanupCallbacks.completeAll()
        for request in ordinary {
            do {
                try await request.value
            } catch {
                Issue.record("ordinary callback failed: \(error)")
            }
        }
        do {
            try await cleanup.value
        } catch {
            Issue.record("cleanup callback failed: \(error)")
        }
        #expect(coordinator.metrics.pendingFrameworkCalls == 0)
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<100_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func capturedError(
        from task: Task<Void, any Error>
    ) async -> (any Error)? {
        do {
            try await task.value
            return nil
        } catch {
            return error
        }
    }
}

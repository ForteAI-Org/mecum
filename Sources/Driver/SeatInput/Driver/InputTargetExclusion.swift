//
//  InputTargetExclusion.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Dispatch
import Synchronization

/// InputTargetExclusion serialises complete input transactions by target PID.
///
/// An `InputDriver` actor serialises only calls made through that one driver.
/// Two drivers can still prepare and restore the same process concurrently, so
/// the process-wide shared instance is the boundary that matters. Different
/// PIDs remain independent.
///
/// Waiting is asynchronous and FIFO. The Mutex protects only queue bookkeeping,
/// and is never held while a caller is suspended or while a continuation is
/// resumed. A PID entry exists only while a lease or waiter exists.
nonisolated package final class InputTargetExclusion: Sendable {

    /// Lease is proof that one complete transaction owns a PID exclusion.
    package struct Lease: Sendable {
        package let wait: Wait?

        package var waitingNanoseconds: UInt64 { wait?.nanoseconds ?? 0 }

        fileprivate let processID: Int32
        fileprivate let id       : UInt64
    }

    /// Wait is the exact interval spent behind a holder of the same PID.
    package struct Wait: Sendable {
        package let startedAtNanoseconds  : UInt64
        package let completedAtNanoseconds: UInt64

        package var nanoseconds: UInt64 {
            completedAtNanoseconds &- startedAtNanoseconds
        }
    }

    /// Cancellation preserves a completed queue interval for command tracing.
    package struct Cancellation: Error, Sendable {
        package let wait: Wait?
    }

    private enum Registration {
        case pending
        case cancelled
    }

    private struct Waiter {
        let id          : UInt64
        let enqueuedAt  : UInt64
        let continuation: CheckedContinuation<Lease, any Error>
    }

    private struct Target {
        var holderID: UInt64
        var waiters : [Waiter?] = []
        var head     = 0
    }

    private struct State {
        var targets      : [Int32: Target]       = [:]
        var registrations: [UInt64: Registration] = [:]
        var queuedPIDs   : [UInt64: Int32]       = [:]
        var nextID       : UInt64                = 0
    }

    private enum RegistrationResolution {
        case cancelled
        case granted(Lease)
        case queued
    }

    private enum CancellationResolution {
        case none
        case resume(CheckedContinuation<Lease, any Error>, Cancellation)
    }

    private enum ReleaseResolution {
        case none
        case resume(CheckedContinuation<Lease, any Error>, Lease)
    }

    package static let shared = InputTargetExclusion()

    private let state = Mutex(State())

    package init() {}

    /// acquire waits for exclusive use of one target process.
    ///
    /// `waitingNanoseconds` is zero when no holder was ahead of this caller. It
    /// measures only time spent behind another transaction, not the Mutex work,
    /// actor scheduling before this call, target verification or system calls.
    package func acquire(processID: Int32) async throws -> Lease {

        guard processID > 0 else { throw InputFailure.processUnavailable(processID: processID) }
        try Task.checkCancellation()

        let id = state.withLock { state in
            let id = state.nextID
            state.nextID &+= 1
            state.registrations[id] = .pending
            return id
        }

        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resolution = state.withLock { state in
                    register(
                        id          : id,
                        processID   : processID,
                        continuation: continuation,
                        state       : &state
                    )
                }

                switch resolution {
                case .cancelled:
                    continuation.resume(throwing: Cancellation(wait: nil))
                case .granted(let lease):
                    continuation.resume(returning: lease)
                case .queued:
                    break
                }
            }
        } onCancel: {
            let resolution = state.withLock { state in
                cancel(id: id, state: &state)
            }
            if case .resume(let continuation, let cancellation) = resolution {
                continuation.resume(throwing: cancellation)
            }
        }

        // A grant can win the queue race just before cancellation. Return no
        // abandoned lease: release it here before reporting the cancellation.
        if Task.isCancelled {
            release(lease)
            throw Cancellation(wait: lease.wait)
        }
        return lease
    }

    /// release gives the PID to the oldest live waiter, or removes its entry.
    package func release(_ lease: Lease) {

        let resolution = state.withLock { state in
            release(lease: lease, state: &state)
        }

        if case .resume(let continuation, let nextLease) = resolution {
            continuation.resume(returning: nextLease)
        }
    }

    /// The live waiter count for semantic tests and performance instrumentation.
    package func waitingCount(processID: Int32) -> Int {
        state.withLock { state in
            guard let target = state.targets[processID] else { return 0 }
            return target.waiters[target.head...].lazy.compactMap { $0 }.count
        }
    }

    /// The number of retained PID entries, exposed only inside the package.
    package var targetCount: Int { state.withLock { $0.targets.count } }

    // MARK: The state machine under the Mutex

    private func register(
        id          : UInt64,
        processID   : Int32,
        continuation: CheckedContinuation<Lease, any Error>,
        state       : inout State
    ) -> RegistrationResolution {

        let registration = state.registrations.removeValue(forKey: id)
        if case .cancelled? = registration {
            return .cancelled
        }

        guard var target = state.targets.removeValue(forKey: processID) else {
            state.targets[processID] = Target(holderID: id)
            return .granted(Lease(wait: nil, processID: processID, id: id))
        }

        let waiter = Waiter(
            id          : id,
            enqueuedAt  : DispatchTime.now().uptimeNanoseconds,
            continuation: continuation
        )
        target.waiters.append(waiter)
        state.targets[processID] = target
        state.queuedPIDs[id] = processID
        return .queued
    }

    private func cancel(id: UInt64, state: inout State) -> CancellationResolution {

        if state.registrations[id] != nil {
            state.registrations[id] = .cancelled
            return .none
        }

        guard let processID = state.queuedPIDs.removeValue(forKey: id),
              var target = state.targets.removeValue(forKey: processID)
        else {
            // The waiter has already been granted or the lease was released.
            return .none
        }

        guard let index = target.waiters[target.head...].firstIndex(where: { $0?.id == id }),
              let waiter = target.waiters[index]
        else {
            state.targets[processID] = target
            state.queuedPIDs[id] = processID
            return .none
        }

        target.waiters[index] = nil
        discardConsumedPrefix(from: &target)
        state.targets[processID] = target
        let wait = Wait(
            startedAtNanoseconds  : waiter.enqueuedAt,
            completedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        return .resume(waiter.continuation, Cancellation(wait: wait))
    }

    private func release(lease: Lease, state: inout State) -> ReleaseResolution {

        guard let current = state.targets[lease.processID], current.holderID == lease.id else {
            assertionFailure("InputTargetExclusion released a lease that was not held")
            return .none
        }
        guard var target = state.targets.removeValue(forKey: lease.processID) else {
            assertionFailure("InputTargetExclusion lost a validated lease")
            return .none
        }

        while target.head < target.waiters.count {
            let index = target.head
            target.head += 1

            guard let waiter = target.waiters[index] else { continue }

            target.waiters[index] = nil
            discardConsumedPrefix(from: &target)
            state.queuedPIDs.removeValue(forKey: waiter.id)
            target.holderID = waiter.id
            state.targets[lease.processID] = target

            let wait = Wait(
                startedAtNanoseconds  : waiter.enqueuedAt,
                completedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            let next = Lease(
                wait     : wait,
                processID: lease.processID,
                id       : waiter.id
            )
            return .resume(waiter.continuation, next)
        }

        // Leaving the target absent is the registry cleanup.
        return .none
    }

    /// Drops historical continuation slots with amortised rather than per-grant
    /// movement. A continuously contended PID therefore retains active depth,
    /// not every waiter it has ever served.
    private func discardConsumedPrefix(from target: inout Target) {

        while target.head < target.waiters.count, target.waiters[target.head] == nil {
            target.head += 1
        }

        guard target.head >= 64, target.head * 2 >= target.waiters.count else { return }
        target.waiters.removeFirst(target.head)
        target.head = 0
    }
}

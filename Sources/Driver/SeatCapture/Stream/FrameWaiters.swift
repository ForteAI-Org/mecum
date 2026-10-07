//
//  FrameWaiters.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import Dispatch
import SeatCore
import Synchronization

/// FrameWaiters hands each frame a running stream presents to the callers waiting for one, without
/// any of them consuming the stream.
///
/// It exists because the shared `frames` sequence cannot be waited on with a bound: cancelling the
/// task that iterates an `AsyncStream` terminates it, so the first wait that timed out ended the
/// stream for every later one while ScreenCaptureKit kept delivering. Here a wait that times out or
/// is cancelled only removes itself, and every continuation is resumed exactly once, under the lock
/// that removes it.
///
/// A frame qualifies for a waiter by the rule `SeatCaptureStream.firstTimestampedFrame` applies:
/// its `displayTime`, converted by `MachAbsoluteContentClock`, is strictly after the waiter's
/// instant and before its deadline. The newest frame presented is kept and offered to a new waiter
/// first, which is what the one-element buffer of `frames` gave the previous wait; it holds the
/// same pool surface that buffer held. `finish` releases it and fails every waiter, present and
/// future, with `frameUnavailable`.
nonisolated final class FrameWaiters: Sendable {

    private struct Waiter: Sendable {
        let notBefore   : UInt64
        let expiresAt   : UInt64
        let continuation: CheckedContinuation<SeatFrame, any Error>

        func accepts(_ displayedAt: UInt64) -> Bool {
            displayedAt > notBefore && displayedAt < expiresAt
        }
    }

    private struct State {
        var waiters   : [UInt64: Waiter] = [:]
        var nextID    : UInt64 = 0
        var newest    : SeatFrame?
        var isFinished = false
    }

    private let state = Mutex(State())
    private let clock = MachAbsoluteContentClock()

    /// How many callers are waiting. Internal: the unit tier asserts that a wait leaves nothing behind.
    var waitingCount: Int { state.withLock { $0.waiters.count } }

    /// Offers a presented frame to every waiter it qualifies for, and keeps it as the newest.
    /// Called on the presenting path; it resumes the waiters after releasing the lock.
    func offer(_ frame: SeatFrame) {
        let displayedAt = displayedAt(frame)
        let served = state.withLock { state -> [CheckedContinuation<SeatFrame, any Error>] in
            guard !state.isFinished else { return [] }
            state.newest = frame
            guard let displayedAt else { return [] }
            let ids = state.waiters.compactMap { $0.value.accepts(displayedAt) ? $0.key : nil }
            return ids.compactMap { state.waiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in served { continuation.resume(returning: frame) }
    }

    /// Ends the frames: every waiter fails with `frameUnavailable`, and so does every later one.
    func finish() {
        let waiting = state.withLock { state -> [Waiter] in
            state.isFinished = true
            state.newest     = nil
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiting { waiter.continuation.resume(throwing: CaptureFailure.frameUnavailable) }
    }

    /// The first frame offered, or the newest one kept, that WindowServer displayed after
    /// `notBefore` (uptime nanoseconds) and before the deadline.
    ///
    /// A frame delivered before its display instant is waited for until that instant. Throws
    /// `timedOut(.still)` when the deadline passes, `frameUnavailable` once the frames ended, and
    /// `CancellationError` when the calling task is cancelled; none of them touches another waiter.
    func first(
        displayedAfter notBefore: UInt64,
        deadline                : CaptureDeadline
    ) async throws -> SeatFrame {

        try deadline.check(.still)
        let id = state.withLock { state -> UInt64 in
            state.nextID &+= 1
            return state.nextID
        }
        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(
                    notBefore   : notBefore,
                    expiresAt   : deadline.expiresAt,
                    continuation: continuation
                )
                let answer = state.withLock { state -> Result<SeatFrame, any Error>? in
                    // Checked under the lock the cancellation handler takes, so one of the two resumes.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.isFinished { return .failure(CaptureFailure.frameUnavailable) }
                    if let newest = state.newest, let shown = displayedAt(newest), waiter.accepts(shown) {
                        return .success(newest)
                    }
                    state.waiters[id] = waiter
                    return nil
                }
                if let answer {
                    continuation.resume(with: answer)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: DispatchTime(uptimeNanoseconds: deadline.expiresAt)
                ) { [self] in
                    end(id, throwing: CaptureFailure.timedOut(.still))
                }
            }
        } onCancel: {
            end(id, throwing: CancellationError())
        }
        try await Self.awaitDisplay(at: displayedAt(frame) ?? 0, deadline: deadline)
        return frame
    }

    /// Waits until `displayedAt`, an uptime instant: ScreenCaptureKit can deliver a frame before its
    /// scheduled display instant. Against the original deadline, never extending it.
    static func awaitDisplay(at displayedAt: UInt64, deadline: CaptureDeadline) async throws {
        var now = DispatchTime.now().uptimeNanoseconds
        while displayedAt > now {
            try await Task.sleep(nanoseconds: displayedAt - now)
            try deadline.check(.still)
            now = DispatchTime.now().uptimeNanoseconds
        }
        try deadline.check(.still)
    }

    private func end(_ id: UInt64, throwing error: any Error) {
        state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume(throwing: error)
    }

    private func displayedAt(_ frame: SeatFrame) -> UInt64? {
        frame.displayTime.flatMap { clock.displayTimeNanoseconds(fromMachTicks: $0) }
    }
}

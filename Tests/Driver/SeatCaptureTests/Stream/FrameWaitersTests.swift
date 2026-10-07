//
//  FrameWaitersTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

@testable import SeatCapture
import Dispatch
import SeatCore
import Testing

/// Waits for a frame of one running stream: a wait that ends without a frame, by its bound or by
/// its caller, must leave the stream serving every later wait.
@Suite("Waiting for a frame of a running stream")
struct FrameWaitersTests {

    private static let clock = MachAbsoluteContentClock()

    /// The uptime instant a frame stamped with `ticks` was displayed at.
    private static func instant(_ ticks: UInt64) throws -> UInt64 {
        try #require(clock.displayTimeNanoseconds(fromMachTicks: ticks))
    }

    /// Returns once `count` callers are registered, so a frame is offered to a wait already made.
    /// Records an issue after five seconds instead of spinning: a wait that ended at once never registers.
    private static func waitUntil(_ waiters: FrameWaiters, holds count: Int) async {
        let giveUpAt = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while waiters.waitingCount != count {
            guard DispatchTime.now().uptimeNanoseconds < giveUpAt else {
                Issue.record("\(waiters.waitingCount) waits registered, expected \(count)")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func wait(
        _ waiters  : FrameWaiters,
        after ticks: UInt64 = 0,
        bound      : Duration = .seconds(2)
    ) -> Task<SeatFrame, any Error> {
        Task {
            try await waiters.first(
                displayedAfter: ticks == 0 ? 0 : try instant(ticks),
                deadline      : CaptureDeadline(timeout: bound)
            )
        }
    }

    @Test("a wait that timed out leaves the stream serving the next wait a later frame")
    func timeoutDoesNotEndTheStream() async throws {
        let waiters = FrameWaiters()
        await #expect(throws: CaptureFailure.timedOut(.still)) {
            try await waiters.first(displayedAfter: 0, deadline: CaptureDeadline(timeout: .milliseconds(30)))
        }
        #expect(waiters.waitingCount == 0)

        let next = Self.wait(waiters)
        await Self.waitUntil(waiters, holds: 1)
        waiters.offer(try #require(makeFakeFrame(receivedAt: 2, displayTime: 20)))
        #expect(try await next.value.receivedAt == 2)
    }

    @Test("a wait its caller cancelled leaves the stream serving a later wait")
    func cancellationDoesNotEndTheStream() async throws {
        let waiters = FrameWaiters()
        let cancelled = Self.wait(waiters)
        await Self.waitUntil(waiters, holds: 1)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(waiters.waitingCount == 0)

        let next = Self.wait(waiters)
        await Self.waitUntil(waiters, holds: 1)
        waiters.offer(try #require(makeFakeFrame(receivedAt: 3, displayTime: 30)))
        #expect(try await next.value.receivedAt == 3)
    }

    @Test("two waits at once with different instants each take the first frame displayed after their own")
    func concurrentWaitsEachTakeTheirFrame() async throws {
        let waiters = FrameWaiters()
        let early = Self.wait(waiters, after: 1_000)
        let late  = Self.wait(waiters, after: 3_000)
        await Self.waitUntil(waiters, holds: 2)

        waiters.offer(try #require(makeFakeFrame(receivedAt: 1, displayTime: 500)))
        waiters.offer(try #require(makeFakeFrame(receivedAt: 2, displayTime: 2_000)))
        #expect(try await early.value.receivedAt == 2)
        #expect(waiters.waitingCount == 1, "the frame at 2000 is not after the late wait's instant")

        waiters.offer(try #require(makeFakeFrame(receivedAt: 3, displayTime: 4_000)))
        #expect(try await late.value.receivedAt == 3)
    }

    @Test("a wait takes the newest frame already presented when it qualifies, never an older one")
    func newestFrameServesANewWait() async throws {
        let waiters = FrameWaiters()
        waiters.offer(try #require(makeFakeFrame(receivedAt: 1, displayTime: 1_000)))
        let served = try await waiters.first(
            displayedAfter: Self.instant(500),
            deadline      : CaptureDeadline(timeout: .seconds(1))
        )
        #expect(served.receivedAt == 1)
        await #expect(throws: CaptureFailure.timedOut(.still)) {
            try await waiters.first(
                displayedAfter: Self.instant(1_000),
                deadline      : CaptureDeadline(timeout: .milliseconds(30))
            )
        }
    }

    @Test("the end of the stream fails the waits under way and every later one")
    func finishEndsEveryWait() async throws {
        let waiters = FrameWaiters()
        let waiting = Self.wait(waiters)
        await Self.waitUntil(waiters, holds: 1)
        waiters.finish()
        await #expect(throws: CaptureFailure.frameUnavailable) { try await waiting.value }
        waiters.offer(try #require(makeFakeFrame(receivedAt: 4, displayTime: 40)))
        await #expect(throws: CaptureFailure.frameUnavailable) {
            try await waiters.first(displayedAfter: 0, deadline: CaptureDeadline(timeout: .seconds(1)))
        }
    }
}

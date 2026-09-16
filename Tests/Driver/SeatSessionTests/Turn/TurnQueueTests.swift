//
//  TurnQueueTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

@testable import SeatSession
import Testing

/// The queue is the one place in the kit where anybody waits, so its order,
/// its generation and its refusals are the whole contract.
@MainActor
@Suite("Turn queue")
struct TurnQueueTests {

    @Test("the first turn is generation one and nothing changed before it")
    func firstTurn() async throws {

        let queue = TurnQueue(markers: { 7 })
        let turn  = try await queue.acquire()

        #expect(turn.generation == 1)
        #expect(!turn.seatChangedSinceLastHold)
        #expect(turn.correlationID == 7)
        #expect(queue.isHeld)
    }

    @Test("the generation advances and never repeats")
    func generationAdvances() async throws {

        let queue = TurnQueue()
        var seen: [UInt64] = []

        for _ in 0..<5 {
            let turn = try await queue.acquire()
            seen.append(turn.generation)
            try queue.release(turn)
        }

        #expect(seen == [1, 2, 3, 4, 5])
    }

    @Test("waiters are served in arrival order")
    func fifo() async throws {

        let queue = TurnQueue()
        let first = try await queue.acquire()

        // Three callers queue behind the holder. They are started in order and
        // each records the generation it was handed.
        let order = Order()

        for index in 1...3 {
            Task { @MainActor in
                if let turn = try? await queue.acquire() {
                    order.record(index: index, generation: turn.generation)
                    try? queue.release(turn)
                }
            }
            // One hop, so the tasks reach `acquire` in the order they were
            // created rather than in whatever order the scheduler prefers.
            await Task.yield()
        }

        #expect(queue.waitingCount == 3)
        try queue.release(first)

        while order.entries.count < 3 { await Task.yield() }

        #expect(order.entries.map(\.index) == [1, 2, 3])
        #expect(order.entries.map(\.generation) == [2, 3, 4])
    }

    @Test("a cancelled waiter leaves the queue without disturbing the ones behind it")
    func cancellationLeavesTheQueue() async throws {

        let queue = TurnQueue()
        let first = try await queue.acquire()

        let cancelled = Task { @MainActor in try await queue.acquire() }
        await Task.yield()
        #expect(queue.waitingCount == 1)

        cancelled.cancel()

        await #expect(throws: CancellationError.self) { try await cancelled.value }

        // The seat is still held by the first caller and the queue is empty:
        // a cancellation is not a release.
        #expect(queue.isHeld)
        while queue.waitingCount > 0 { await Task.yield() }

        try queue.release(first)
        #expect(!queue.isHeld)
    }

    @Test("an issue that passed makes the next hold say the seat changed")
    func issueMarksTheNextHold() async throws {

        let queue = TurnQueue()
        let first = try await queue.acquire()

        queue.recordIssue()
        try queue.release(first)

        let second = try await queue.acquire(after: first)
        #expect(second.seatChangedSinceLastHold)
    }

    @Test("a clean release and a straight return says nothing changed")
    func cleanReturn() async throws {

        let queue = TurnQueue()
        let first = try await queue.acquire()
        try queue.release(first)

        let second = try await queue.acquire(after: first)
        #expect(!second.seatChangedSinceLastHold)
    }

    @Test("somebody else holding the seat in between says the seat changed")
    func anotherHolder() async throws {

        let queue = TurnQueue()
        let mine  = try await queue.acquire()
        try queue.release(mine)

        let somebodyElse = try await queue.acquire()
        try queue.release(somebodyElse)

        let again = try await queue.acquire(after: mine)
        #expect(again.seatChangedSinceLastHold)
    }

    @Test("releasing a turn that is not the one out is refused")
    func releasingSomebodyElsesHold() async throws {

        let queue = TurnQueue()
        let held  = try await queue.acquire()
        let fake  = Turn(generation: 99, seatChangedSinceLastHold: false, correlationID: 1)

        #expect(throws: SessionFailure.turnNotHeld(generation: 99)) {
            try queue.release(fake)
        }
        #expect(queue.current == held)
    }

    @Test("a failed seat throws every waiter out instead of leaving them waiting forever")
    func failAllWakesTheQueue() async throws {

        let queue = TurnQueue()
        _ = try await queue.acquire()

        let waiting = Task { @MainActor in try await queue.acquire() }
        await Task.yield()
        #expect(queue.waitingCount == 1)

        queue.failAll(with: SessionFailure.seatNotReady(.failed))

        await #expect(throws: SessionFailure.seatNotReady(.failed)) { try await waiting.value }
        #expect(!queue.isHeld)
    }

    /// A recorder the queued tasks can write into from the main actor.
    @MainActor
    final class Order {
        private(set) var entries: [(index: Int, generation: UInt64)] = []
        func record(index: Int, generation: UInt64) {
            entries.append((index, generation))
        }
    }
}

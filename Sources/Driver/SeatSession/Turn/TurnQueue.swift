//
//  TurnQueue.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// TurnQueue is where a caller waits for use of an Agent Seat. Seat state
/// refusals never queue a Command. The lower Background Driver has a separate
/// process exclusion and re-verifies window identity after that wait.
///
/// Arrival order, and cancellable. A waiter that is cancelled leaves the queue
/// without disturbing the ones behind it, and a cancellation that races with a
/// grant loses: the Turn was already handed out, so the holder has to release
/// it.
///
/// It holds no system state at all, which is why the queue's whole behaviour is
/// a unit test: order, generation, the changed flag and the refusals.
public final class TurnQueue {

    /// One caller waiting for the seat.
    private struct Waiter {
        let id          : UInt64
        let previous    : Turn?
        let continuation: CheckedContinuation<Turn, any Error>
    }

    /// The generation of the Turn handed out last, zero before the first one.
    /// Monotonic: it never repeats and never goes back.
    public private(set) var generation: UInt64 = 0

    /// The Turn currently held, nil when the seat is free.
    public private(set) var current: Turn?

    /// True when an Issue passed through the seat since the last release. It is
    /// what makes `seatChangedSinceLastHold` true for a consumer that held the
    /// seat, released it cleanly and is coming straight back.
    private var issueSinceLastRelease = false

    private var waiters      : [Waiter] = []
    private var nextWaiterID : UInt64   = 0

    /// Where the correlation markers come from. Zero is reserved by the fence
    /// (an unmarked event already carries it), so the range starts at one.
    private let markers: () -> Int64

    public init(markers: @escaping () -> Int64 = { Int64.random(in: 1...Int64.max) }) {
        self.markers = markers
    }

    /// True when a Turn is out.
    public var isHeld: Bool { current != nil }

    /// How many callers are waiting.
    public var waitingCount: Int { waiters.count }

    /// acquire waits in arrival order and hands out the next Turn.
    ///
    /// `previous` is the caller's own last Turn, and passing it is what turns
    /// `seatChangedSinceLastHold` from a guess into a fact: with it the queue
    /// can tell "nothing happened since your last hold" from "somebody else
    /// held the seat in between". Without it the flag reports only the Issues,
    /// which is the honest answer for a caller that does not track its holds.
    public func acquire(after previous: Turn? = nil) async throws -> Turn {

        try Task.checkCancellation()

        if current == nil, waiters.isEmpty { return grant(after: previous) }

        let id = nextWaiterID
        nextWaiterID &+= 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, previous: previous, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(waiter: id) }
        }
    }

    /// release gives the seat back and wakes the next waiter.
    ///
    /// It refuses a Turn that is not the one out: releasing somebody else's
    /// hold would hand the seat to a third caller while the real holder is
    /// still acting.
    public func release(_ turn: Turn) throws {

        guard let current, current == turn else {
            throw SessionFailure.turnNotHeld(generation: turn.generation)
        }

        self.current = nil

        guard !waiters.isEmpty else { return }

        let next = waiters.removeFirst()
        next.continuation.resume(returning: grant(after: next.previous))
    }

    /// Records that an Issue passed through the seat, so the next holder is
    /// told to perceive again before acting.
    public func recordIssue() {
        issueSinceLastRelease = true
    }

    /// Fails every waiter and drops the current hold, which is what a failed
    /// seat owes the callers queued behind it: an error now rather than a wait
    /// that will never end.
    public func failAll(with error: any Error) {

        let queued = waiters
        waiters.removeAll()
        current = nil

        for waiter in queued { waiter.continuation.resume(throwing: error) }
    }

    // MARK: The private half

    private func grant(after previous: Turn?) -> Turn {

        generation &+= 1

        let anotherHeldTheSeat = previous.map { $0.generation != generation - 1 } ?? false

        let turn = Turn(
            generation              : generation,
            seatChangedSinceLastHold: issueSinceLastRelease || anotherHeldTheSeat,
            correlationID           : markers()
        )

        // The flag is consumed by the hold that is told about it, not cleared
        // by the release: an Issue detected while the seat was held has to
        // reach the **next** holder, and clearing it at release time is exactly
        // how it would reach nobody.
        issueSinceLastRelease = false

        current = turn
        return turn
    }

    private func cancel(waiter id: UInt64) {

        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }

        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

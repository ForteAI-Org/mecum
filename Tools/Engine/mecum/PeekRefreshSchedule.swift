import Foundation

/// PeekRefreshSchedule times the next observation from the previous start, not its completion.
/// Input changes the generation and requests a fresh read after a short settling period. Callers
/// own the clock and the single in-flight task; stale completions cannot postpone newer input.
struct PeekRefreshSchedule {
    struct Ticket {
        let generation: Int
        let started: ContinuousClock.Instant
    }

    private let interval: Duration
    private var generation = 0
    private(set) var nextObservation: ContinuousClock.Instant

    init(interval: Duration, now: ContinuousClock.Instant) {
        self.interval = interval
        nextObservation = now
    }

    mutating func invalidate(at now: ContinuousClock.Instant) {
        generation += 1
        nextObservation = now.advanced(by: .milliseconds(100))
    }

    func ticket(at now: ContinuousClock.Instant) -> Ticket {
        Ticket(generation: generation, started: now)
    }

    func isCurrent(_ ticket: Ticket) -> Bool { ticket.generation == generation }

    mutating func complete(_ ticket: Ticket, at now: ContinuousClock.Instant) {
        guard isCurrent(ticket) else { return }
        nextObservation = max(now, ticket.started.advanced(by: interval))
    }
}

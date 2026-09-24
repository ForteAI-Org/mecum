//
//  SeatQueue.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Observation

/// The way a worker gets a seat, and the only way.
///
/// A seat is scarce: the kit holds one today and the measurement says a Mac is
/// comfortable with about eight. Every consumer therefore has to be able to
/// wait, and a consumer that can wait will only write that correctly if waiting
/// is the structure rather than its own good manners. So `SeatBroker` no longer
/// hands out sessions: this does, and it hands one out only when a seat is
/// free.
///
/// ## Waiting is real
///
/// With `capacity` 1 the second caller does not receive an `AgentSession` until
/// the first gives its seat back. It is not a token it may ignore and it is not
/// advisory: there is no other way to reach a session, so an application that
/// never waits cannot be written against this type.
///
/// ## The seat is kept warm, not remade
///
/// Creating the virtual display behind a seat costs about 380 ms, and holding
/// an idle one costs nothing measurable — neither system CPU nor window server
/// latency moved across 15 runs of 8 displays at three resolutions and three
/// refresh rates. So a seat given back is parked here and handed to the next
/// entry rather than torn down: the pool is stable and reused, which is what
/// those measurements ask for. Whatever the previous holder left on the seat is
/// replaced the moment the next one calls `open(applicationNamed:)`, which is
/// the same path the planner already takes when it changes application
/// mid-run.
///
/// ## Order
///
/// First in, first out. Not the other way round: with a stack the first arrival
/// can starve for as long as new work keeps coming, which for a queue of tasks
/// a person is waiting on is never the behaviour anyone wants.
///
/// ## What is not here
///
/// No priorities, no fairness weighting, no timeouts. One seat and a handful of
/// workers do not need a scheduler, and a scheduler nobody has measured a need
/// for is a set of decisions made in the dark.
/// ponytail: FIFO with an Array, positions read off the index; if the queue
/// ever holds enough entries for the O(n) removal to matter, it will also be
/// big enough to deserve a real scheduler, and both arrive together.
@MainActor
@Observable
public final class SeatQueue {

    /// One worker's place in the queue. It carries what a list draws and
    /// nothing else: the run history is a different record, kept elsewhere, and
    /// an entry that has finished is gone from here.
    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: UUID
        /// The consumer's name for the entry, which is not always for a person to read: a worker
        /// waits under its id, and the lab under "Mecum".
        public let label: String
        public internal(set) var state: State
        /// When it joined the queue, so a list can say how long it has waited.
        public let since: Date
    }

    /// Where an entry is. There is no `finished` and no `failed`: an entry that
    /// is done has left, and how it ended is the caller's own returned value or
    /// thrown error, never a flag another reader has to interpret.
    public enum State: Sendable, Equatable {
        /// In line. Its position is its index among the other waiting entries.
        case waiting
        /// Holding a seat right now.
        case acting
    }

    /// How many entries may be `acting` at once.
    ///
    /// **One today**, and the one number that changes when more becomes
    /// possible. What holds it at one is not this type: `SeatHost.makeSeat`
    /// answers `seatLimitReached` for a second seat, and a second host cannot
    /// start either, because its topology baseline would include the first
    /// host's virtual display and the process-wide cursor fence refuses the
    /// different region with `regionMismatch`. A registry of the kit's own
    /// displays, excluded from the baseline and from the fence's region, is what
    /// unblocks it — and then this is a number, not a redesign.
    public let capacity: Int

    /// The live queue: acting entries first, then the waiting ones in the order
    /// they arrived. A consumer draws this and reads a position off the index.
    public private(set) var entries: [Entry] = []

    @ObservationIgnored private let broker: SeatBroker
    /// Seats given back and kept warm, never torn down between entries.
    @ObservationIgnored private var warm: [AgentSession] = []
    /// The waiting entries' continuations, resumed by `admitNext`.
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(broker: SeatBroker, capacity: Int) {
        self.broker = broker
        self.capacity = max(1, capacity)
    }

    // MARK: Asking for a seat

    /// Joins the queue, waits its turn, runs `body` with the seat it is granted
    /// and gives the seat back however `body` ends.
    ///
    /// The closure form, for work that is one async scope. A consumer driven by
    /// separate messages — a chat turn at a time — cannot be one scope and uses
    /// `acquire` instead.
    public func run<T>(
        _ label: String,
        _ body: @MainActor (AgentSession) async throws -> T
    ) async throws -> T {
        let lease = try await acquire(label)
        defer { lease.giveBack() }
        return try await body(lease.session)
    }

    /// Joins the queue, waits its turn, and hands back a lease on the seat.
    ///
    /// The caller owns the lease and **must** give it back; until it does, with
    /// `capacity` 1, nobody else runs. Cancelling the calling task while it is
    /// still waiting leaves the queue.
    public func acquire(_ label: String) async throws -> SeatLease {
        let id = UUID()
        entries.append(Entry(id: id, label: label, state: .waiting, since: Date()))

        if actingCount < capacity {
            // A free seat now: the state is set before returning, so the slot is
            // taken and a second caller in the same turn of the main actor sees
            // it gone.
            setState(id, .acting)
        } else {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // The turn may have come while this was being set up, which
                    // on the main actor it cannot have, but a resumed entry is
                    // already `.acting` and must not wait for a second admission.
                    if entries.first(where: { $0.id == id })?.state == .acting {
                        continuation.resume()
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id) }
            }
        }

        // `admitNext` marks the entry acting before it resumes, so reaching here
        // means the slot is already this entry's.
        let session = await takeWarm() ?? broker.openSession()
        return SeatLease(id: id, session: session, queue: self)
    }

    /// A parked seat made with the display the broker makes now. One made with another display,
    /// parked before the display was changed or given back after, is closed rather than handed on.
    private func takeWarm() async -> AgentSession? {
        while let session = warm.popLast() {
            if session.display == broker.display { return session }
            _ = await session.close()
        }
        return nil
    }

    /// Gives up a place in the queue. It affects a waiting entry, which leaves
    /// with a `CancellationError`; an entry that is already acting ends by
    /// giving its lease back, which is the only thing that frees its seat.
    public func cancel(_ id: Entry.ID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        entries.removeAll { $0.id == id }
        continuation.resume(throwing: CancellationError())
    }

    /// Closes every parked seat. The queue is usable afterwards and makes new
    /// ones; this is for a consumer shutting down, so that a process exiting
    /// does not leave a virtual display and an adopted window behind.
    public func shutdown() async {
        let parked = warm
        warm.removeAll()
        for session in parked { _ = await session.close() }
    }

    // MARK: Inside

    private var actingCount: Int { entries.count { $0.state == .acting } }

    private func setState(_ id: Entry.ID, _ state: State) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = state
    }

    /// Called by a lease being given back. The seat is parked rather than
    /// closed, and the next waiting entry is admitted.
    fileprivate func giveBack(_ id: Entry.ID, session: AgentSession) {
        entries.removeAll { $0.id == id }
        // A session the holder closed is not parked: `close` takes the display
        // down and refuses every later Command as a closed session, so handing
        // it to the next entry would hand over a seat that cannot act. The next
        // entry makes a fresh one, and pays the setup this pool exists to
        // avoid — which is the right price for a seat somebody ended on
        // purpose.
        if session.isOpen { warm.append(session) }
        admitNext()
    }

    /// Admits as many waiting entries as there are free seats.
    ///
    /// The state is set **before** the continuation is resumed: a resumed task
    /// does not run until the main actor next suspends, and in that window a
    /// fresh `acquire` must already see the slot taken.
    private func admitNext() {
        while actingCount < capacity,
              let next = entries.first(where: { $0.state == .waiting }) {
            setState(next.id, .acting)
            guard let continuation = waiters.removeValue(forKey: next.id) else {
                // Admitted before it reached its continuation; `acquire` checks
                // for exactly this and does not wait.
                continue
            }
            continuation.resume()
        }
    }
}

/// A seat held until it is given back.
///
/// It exists because a consumer driven by separate messages cannot hold a seat
/// inside one `async` scope, and because a seat nobody gives back is a seat
/// nobody else can have: making the handing back an explicit act of an object
/// the caller owns is the shape that says so.
@MainActor
public final class SeatLease {

    /// The seat. Valid until `giveBack`, and using it afterwards is using a
    /// seat somebody else may now hold.
    public let session: AgentSession

    private let id: SeatQueue.Entry.ID
    private weak var queue: SeatQueue?
    private var isGivenBack = false

    fileprivate init(id: SeatQueue.Entry.ID, session: AgentSession, queue: SeatQueue) {
        self.id = id
        self.session = session
        self.queue = queue
    }

    /// Returns the seat to the queue and lets the next entry in. Idempotent: a
    /// second call is nothing, which is what lets a `defer` and an explicit
    /// release coexist.
    public func giveBack() {
        guard !isGivenBack else { return }
        isGivenBack = true
        queue?.giveBack(id, session: session)
    }

    /// A lease that is dropped without being given back would strand the seat
    /// for the life of the process, so it gives itself back. It is the safety
    /// net and not the contract: `giveBack` at a point the caller chooses is
    /// what makes the wait of the next entry end when it should.
    deinit {
        guard !isGivenBack else { return }
        let id = self.id, session = self.session, queue = self.queue
        Task { @MainActor in queue?.giveBack(id, session: session) }
    }
}

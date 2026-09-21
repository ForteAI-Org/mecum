//
//  SeatStateSubscription.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// SeatStateSubscription is one consumer's registered view of the seat's
/// coherent state, with the reading it started from.
///
/// ## Why the first reading comes with the subscription
///
/// Reading the state and then registering leaves a hole: a change between the
/// two is never seen and never replaced, so the consumer would show a state that
/// is already gone and would not know. `current` is taken in the same main actor
/// turn the registration happens in, so every update after it is newer than it
/// and `revision` orders them.
///
/// ## Ownership
///
/// The owner is whoever asked for it and the cancellation is explicit: a view
/// that is dismantled calls `cancel`. Cancelling finishes `updates`, so an
/// iteration ends rather than waiting forever. The buffer keeps the newest
/// values only, which is what stops a slow consumer from accumulating snapshots
/// or from holding up the focus path; a consumer that missed values still has a
/// complete current state in the next one it reads.
@MainActor
public final class SeatStateSubscription {

    /// The state at the moment of registration.
    public let current: SeatCoherentState

    /// Every state newer than `current`, oldest first, ending on `cancel` or on
    /// the end of the seat.
    public let updates: AsyncStream<SeatCoherentState>

    private let channel: AsyncStream<SeatCoherentState>.Continuation
    private let onCancel: @MainActor (SeatStateSubscription) -> Void
    private var isCancelled = false

    init(
        current : SeatCoherentState,
        onCancel: @escaping @MainActor (SeatStateSubscription) -> Void
    ) {
        var continuation: AsyncStream<SeatCoherentState>.Continuation!
        self.updates = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation = $0 }
        self.channel  = continuation
        self.current  = current
        self.onCancel = onCancel
    }

    /// Publishes one newer state. Ignored after cancellation, so a state
    /// produced while the owner was tearing down is not delivered to a view that
    /// has already gone.
    func publish(_ state: SeatCoherentState) {
        guard !isCancelled else { return }
        channel.yield(state)
    }

    /// Ends the subscription. Idempotent, and the only way it ends other than
    /// the seat itself finishing.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        channel.finish()
        onCancel(self)
    }

    /// Ends the subscription because the seat did. Kept apart from `cancel` so
    /// the seat does not call back into its own registry while iterating it.
    func finish() {
        guard !isCancelled else { return }
        isCancelled = true
        channel.finish()
    }
}

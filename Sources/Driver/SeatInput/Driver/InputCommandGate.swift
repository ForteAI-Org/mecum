import Synchronization

/// A synchronous stop at command boundaries. A command already posting stays
/// atomic (a down is never abandoned without its up); the next command cannot
/// start while focus is unconfirmed. No input is queued or replayed here.
///
/// ## Why the stop is a set of causes and not a flag
///
/// Two stops overlap in practice: the person activates the target while the
/// seat is moving a window onto the stage, and whichever finishes first would
/// reopen the gate for the other one if the stop were a single boolean. So the
/// gate is closed while **any** cause is present and each owner removes only
/// its own. The type is `public` because `CommandSending` names it; every
/// member that can act on it stays `package`, so a consumer can hold one and
/// do nothing with it.
nonisolated public final class InputCommandGate: Sendable {

    /// Why input is stopped. Each case has one owner and only that owner
    /// resolves it.
    package enum PauseCause: Sendable, Hashable, CaseIterable {

        /// The person's focus is being restored. `UserFocusRecovery` opens it
        /// on activation and closes it when the focused user window is
        /// verified twice or the person took control.
        case focusRecovery

        /// The seat is staging a window or moving its operating target.
        /// `AgentSeat` opens and closes it around one transaction.
        case windowTransfer

        /// Focus recovery stopped. Deliberately terminal: nothing resolves it,
        /// so a seat whose recovery went away never posts again.
        case focusRecoveryStopped
    }

    private let causes = Mutex<Set<PauseCause>>([])
    private let preparation = Mutex<(@MainActor @Sendable (Int64) async throws -> Void)?>(nil)

    package init() {}

    package var isPaused: Bool { causes.withLock { !$0.isEmpty } }

    /// The causes holding the gate closed right now, for a report or a test.
    package var pauseCauses: Set<PauseCause> { causes.withLock { $0 } }

    package func pause(_ cause: PauseCause) { causes.withLock { _ = $0.insert(cause) } }

    package func resume(_ cause: PauseCause) { causes.withLock { _ = $0.remove(cause) } }

    package func setPreparation(_ prepare: @escaping @MainActor @Sendable (Int64) async throws -> Void) {
        preparation.withLock { $0 = prepare }
    }

    package func prepare(correlationID: Int64) async throws {
        try check()
        if let prepare = preparation.withLock({ $0 }) {
            try await prepare(correlationID)
        }
        try Task.checkCancellation()
        try check()
    }

    package func check() throws {
        guard !isPaused else { throw InputFailure.inputPaused }
    }
}

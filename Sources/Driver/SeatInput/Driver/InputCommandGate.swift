import Synchronization

/// A synchronous stop at command boundaries. A command already posting stays
/// atomic (a down is never abandoned without its up); the next command cannot
/// start while focus is unconfirmed. No input is queued or replayed here.
nonisolated package final class InputCommandGate: Sendable {
    private let paused = Mutex(false)
    private let preparation = Mutex<(@MainActor @Sendable (Int64) async throws -> Void)?>(nil)

    package init() {}

    package var isPaused: Bool { paused.withLock { $0 } }
    package func pause() { paused.withLock { $0 = true } }
    package func resume() { paused.withLock { $0 = false } }

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

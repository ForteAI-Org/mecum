import SeatCore

/// A sequence refused after earlier Commands were posted. The completed
/// Receipts must be confirmed; replaying the original sequence is incorrect.
/// Preparation progress and its typed cleanup failure remain attached when
/// that shared state also needs recovery.
nonisolated public struct InputSequenceFailure: Error, Sendable {
    public let completedReceipts: [InputReceipt]
    public let cause: any Error
    public let progress: InputProgress?
    public let cleanupCause: (any Error)?

    public init(
        completedReceipts: [InputReceipt],
        cause            : any Error,
        progress         : InputProgress? = nil,
        cleanupCause     : (any Error)? = nil
    ) {
        self.completedReceipts = completedReceipts
        self.cause             = cause
        self.progress          = progress
        self.cleanupCause      = cleanupCause
    }
}

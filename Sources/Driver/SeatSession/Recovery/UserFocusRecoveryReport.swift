import SeatCore

/// Focus is recovered by observation, never by interpreting a private return
/// code as proof. Latency starts when the kit detects the activation.
nonisolated public struct UserFocusRecoveryReport: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case restoring, restored, waitingForUser, userTookControl, cancelled
    }

    public let outcome: Outcome
    public let destination: WindowReference?
    public let activatingProcessID: Int32
    public let requestCode: Int32?
    /// First notification or sample that observed the user's application in
    /// front again. Window verification can complete later than this.
    public let frontmostRestoredNanoseconds: UInt64?
    public let elapsedNanoseconds: UInt64
    public let detail: String
    public let timing: UserFocusRecoveryTiming
}

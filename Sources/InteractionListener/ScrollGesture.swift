import Foundation

/// ScrollGesture coalesces ticks only within one window and one uninterrupted input sequence.
/// A target change or another input flushes the previous gesture. Quiet time uses a monotonic clock,
/// and `deadline` tells the adapter when to wake once instead of ticking while nothing scrolls.
public struct ScrollGesture: Sendable {
    public static let quiet = 0.5
    private var pending: InputRecord?

    public init() {}

    /// The monotonic second at which the pending gesture settles, nil while nothing is pending.
    public var deadline: Double? { pending.map { $0.endedAt + Self.quiet } }

    public mutating func append(_ tick: InputRecord) -> InputRecord? {
        precondition(tick.kind == .scrollDelta)
        guard let previous = pending else {
            pending = tick
            return nil
        }
        if let merged = Self.merge(previous, tick) {
            pending = merged
            return nil
        }
        pending = tick
        return previous
    }

    public mutating func settled(at now: Double) -> InputRecord? {
        guard let pending, now - pending.endedAt >= Self.quiet else { return nil }
        return take()
    }

    /// Flushes even a zero-net gesture: scrolling out and back is still user activity.
    public mutating func take() -> InputRecord? {
        defer { pending = nil }
        return pending
    }

    /// Joins a later scroll to an earlier one when only scrolling separates them on the same surface.
    /// The queue uses the same rule to aggregate settled gestures it cannot publish yet.
    static func merge(_ gesture: InputRecord, _ next: InputRecord) -> InputRecord? {
        guard gesture.kind == .scrollDelta, next.kind == .scrollDelta,
              gesture.revision == next.precedingRevision, gesture.sameTarget(as: next) else { return nil }
        var merged = gesture
        merged.x = next.x
        merged.y = next.y
        merged.valueA += next.valueA
        merged.valueB += next.valueB
        merged.timestamp = next.timestamp
        merged.revision = next.revision
        return merged
    }
}

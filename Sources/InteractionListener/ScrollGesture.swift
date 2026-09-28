import Foundation

/// ScrollGesture coalesces ticks only within one window and one uninterrupted input sequence.
/// A target change or another input flushes the previous gesture. Quiet time uses a monotonic clock.
public struct ScrollGesture: Sendable {
    private var pending: InteractionEvent?

    public init() {}

    public mutating func append(_ event: InteractionEvent) -> InteractionEvent? {
        precondition(event.kind == .scroll)
        var finished: InteractionEvent?
        if let previous = pending,
           previous.window != event.window || previous.processID != event.processID
            || previous.sourceProcessID != event.sourceProcessID
            || previous.revision != event.precedingRevision {
            finished = take()
        }
        if var current = pending {
            current.point = event.point
            current.deltaX += event.deltaX
            current.deltaY += event.deltaY
            current.endedAt = event.endedAt
            current.revision = event.revision
            pending = current
        } else {
            pending = event
        }
        return finished
    }

    public mutating func settled(at now: Double, quiet: Double = 0.5) -> InteractionEvent? {
        guard let pending, now - pending.endedAt >= quiet else { return nil }
        return take()
    }

    /// Flushes even a zero-net gesture: scrolling out and back is still user activity.
    public mutating func take() -> InteractionEvent? {
        defer { pending = nil }
        return pending
    }
}

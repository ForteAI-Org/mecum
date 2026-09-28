import CoreGraphics

/// HoverDwell emits once after a still pointer has remained on one surface for 1.2 seconds.
/// Input resets dwell. Time is supplied by the adapter, with no polling or OS calls in this value.
public struct HoverDwell: Sendable {
    private var point: CGPoint?
    private var window: InteractionWindow?
    private var since: Double = 0
    private var emitted = false

    public init() {}

    public mutating func reset(at now: Double) {
        point = nil
        window = nil
        since = now
        emitted = false
    }

    public mutating func sample(point next: CGPoint, window nextWindow: InteractionWindow?, at now: Double) -> Bool {
        if window != nextWindow || point.map({ hypot(next.x - $0.x, next.y - $0.y) > 3 }) ?? true {
            point = next
            window = nextWindow
            since = now
            emitted = false
        }
        guard nextWindow != nil, !emitted, now - since >= 1.2 else { return false }
        emitted = true
        return true
    }
}

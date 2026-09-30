import CoreGraphics

/// HoverDwell emits once after a still pointer has remained on one surface for 1.2 seconds.
/// Movement beyond three points or onto another routed surface re-anchors it; input restarts it in place.
/// It only computes a deadline from supplied times: the adapter arms one timer from it, so a still or
/// idle pointer costs no wakeups and this value makes no OS calls.
public struct HoverDwell: Sendable {
    public static let delay = 1.2
    private var anchor: CGPoint?
    private var surface = 0
    public private(set) var deadline: Double?

    public init() {}

    public mutating func moved(to point: CGPoint, surface nextSurface: Int, at now: Double) {
        if let anchor, surface == nextSurface, hypot(point.x - anchor.x, point.y - anchor.y) <= 3 { return }
        anchor = point
        surface = nextSurface
        deadline = now + Self.delay
    }

    /// Input restarts the wait at the current anchor, so a pointer left still after a click hovers again.
    public mutating func restart(at now: Double) {
        guard anchor != nil else { return }
        deadline = now + Self.delay
    }

    /// True once when the deadline has passed with no movement or input since it was armed.
    public mutating func fire(at now: Double) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}

import CoreGraphics

/// Which way a container scrolls. Came with the descriptor vocabulary T5 deleted; kept here
/// because the two scroll files T7 still has to port are written in terms of it.
public enum ScrollAxis: String, Codable, Equatable, Sendable { case vertical, horizontal }

/// How one scroll step is expressed. AX containers use an ABSOLUTE fraction (set the scroll bar's
/// AXValue); opaque containers (no AX fraction to read/set) use RELATIVE wheel ticks (+down / −up).
public enum StepStrategy: Equatable, Sendable {
    case absoluteFraction(Double)
    case relativeTicks(Int)
}

/// One scroll command for a container on an axis.
public struct ScrollAction: Equatable, Sendable {
    public var containerID: String
    public var axis: ScrollAxis
    public var strategy: StepStrategy
    public init(containerID: String, axis: ScrollAxis, strategy: StepStrategy) {
        self.containerID = containerID
        self.axis = axis
        self.strategy = strategy
    }
    /// Convenience for the AX driver + existing tests: the absolute fraction (0 for a relative step).
    public var targetFraction: Double {
        if case .absoluteFraction(let f) = strategy { return f }
        return 0
    }
}

/// A bounded, ordered plan of scroll steps to try while hunting an off-screen target. Finite by
/// construction → the control loop can't scroll forever.
public struct ScrollPlan: Equatable, Sendable {
    public let containerID: String
    public let axis: ScrollAxis
    var queue: [StepStrategy]
    public var canScroll: Bool { !queue.isEmpty }
}

/// Pure, deterministic scroll planning — NO Accessibility, NO display, NO ML. Two flavours:
/// • AX (`makePlan`): absolute fractions — restore the capture-time position first, then search outward.
/// • Opaque (`makeOpaquePlan`): relative wheel ticks — go the inferred direction first (bigger then
///   bigger), then the opposite, all finite & bounded (the loop re-locates via the gated cascade after
///   each, so "found" is never decided here).
public enum ScrollPlanner {
    /// AX path: ordered ABSOLUTE fractions. Restore where the target was visible, then expand outward.
    public static func makePlan(containerID: String, axis: ScrollAxis,
                                capturedFraction: Double, currentFraction: Double,
                                stepFraction: Double) -> ScrollPlan {
        let cap = clamp(capturedFraction)
        let step = max(0.05, min(0.5, stepFraction))
        var targets: [Double] = []
        func add(_ v: Double) {
            let c = clamp(v)
            if !targets.contains(where: { abs($0 - c) < 0.02 }) { targets.append(c) }
        }
        add(cap)
        var k = 1
        while Double(k) * step <= 1.0 + step { add(cap + Double(k) * step); add(cap - Double(k) * step); k += 1 }
        add(0); add(1)
        return ScrollPlan(containerID: containerID, axis: axis, queue: targets.map { .absoluteFraction($0) })
    }

    /// Opaque path: a budget of UNIFORM small steps seeded toward the inferred direction (−1 = up,
    /// +1 = down). The opaque driver RE-INFERS direction from the live frame on every step and reverses
    /// on overshoot, and uses a fixed small magnitude — so the plan no longer escalates or hard-codes a
    /// reverse probe; it just bounds how many steps the hunt may take. Finite by construction.
    public static func makeOpaquePlan(containerID: String, axis: ScrollAxis, direction: Int, maxSteps: Int) -> ScrollPlan {
        let dir = direction >= 0 ? 1 : -1
        let steps = max(1, maxSteps)
        let queue = Array(repeating: StepStrategy.relativeTicks(dir), count: steps)
        return ScrollPlan(containerID: containerID, axis: axis, queue: queue)
    }

    /// Dequeue the next step, or nil when the plan is exhausted.
    public static func next(_ plan: inout ScrollPlan) -> ScrollAction? {
        guard !plan.queue.isEmpty else { return nil }
        return ScrollAction(containerID: plan.containerID, axis: plan.axis, strategy: plan.queue.removeFirst())
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

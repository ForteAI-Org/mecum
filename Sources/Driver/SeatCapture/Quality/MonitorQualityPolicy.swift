//
//  MonitorQualityPolicy.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// MonitorQualityPolicy decides when the Monitor gives something up. It is a
/// value with no dependencies, so the whole degradation ladder is testable on
/// synthetic series instead of on a real display.
///
/// ## The two signals, in order
///
/// **Coalescence** is primary: the share of frames the newest-wins slot threw
/// away because the main actor had not presented the previous one. It costs
/// nothing to measure, it is taken inside the pipeline being judged, and it
/// rises the moment the presenting side falls behind.
///
/// **CPU** is secondary: the percent of one core the consumer attributes **to
/// the Monitor**, handed in by its heartbeat once a second. Attributable, not
/// the whole process, and that distinction is not pedantry: the benchmark's
/// own scene costs 6,5 % of a core before a stream exists, so a policy fed the
/// process total degrades a Monitor that is behaving perfectly. Measured, on
/// the first run of `monitor-30`, which walked down a rung on the cost of the
/// window it was filming. A consumer that cannot attribute a share passes nil
/// rather than the total.
///
/// ## Two readings, not one
///
/// A single reading over the limit does not degrade. One second of the person's
/// machine doing something else is not the Monitor's fault, and a policy that
/// reacted to it would walk down the ladder on the first spike and never come
/// back. Two consecutive readings are asked for, and a level change resets the
/// count so the new rung is judged on its own evidence.
///
/// ## No way back up
///
/// The ladder only goes down. Spec section 5 asks for automatic degradation
/// and says nothing about recovery, and a policy that climbed back would need a
/// hysteresis nobody has measured: it would find the level that oscillates and
/// stay there, reconfiguring the stream twice a second. The consumer that wants
/// the top level back has `start` and `stop`.
nonisolated public struct MonitorQualityPolicy: Sendable, Equatable {

    /// The coalescence budget of spec section 8: one percent.
    public static let coalescenceLimit = 0.01

    /// The CPU budget of spec section 8 for the Monitor: eight percent of one
    /// core, net of the scene that produces the frames. The reading is compared
    /// to it as given, so it has to be net too.
    public static let cpuPercentLimit = 8.0

    /// The same at the 120 level, which spec section 8 calls provisional at
    /// twelve percent: twice the frames through the same path.
    public static let cpuPercentLimitAt120 = 12.0

    /// The limit for the rung being judged, and it has to be per rung: the
    /// reading is the cost of the level the Monitor is on right now, so judging
    /// 120 against the 60 budget makes the top rung unreachable by
    /// construction. Measured: a 120 run with a real Metal producer degraded
    /// itself twice inside twenty seconds at 8,8 % attributable, which is inside
    /// its own budget and outside the one it was being compared to.
    public static func cpuPercentLimit(at frameRate: MonitorFrameRate) -> Double {
        frameRate == .oneHundredTwenty ? cpuPercentLimitAt120 : cpuPercentLimit
    }

    /// Consecutive readings over a limit before anything is given up.
    public static let readingsToDegrade = 2

    /// The rung the Monitor is on.
    public private(set) var quality: MonitorQuality

    private var coalescenceReadings = 0
    private var cpuReadings         = 0

    public init(quality: MonitorQuality = .standard) {
        self.quality = quality
    }

    /// Takes one reading and answers with the level change it caused, or nil.
    ///
    /// `attributableCpuPercent` is optional because the reading belongs to the
    /// consumer's heartbeat and a consumer without one is not thereby wrong: a
    /// nil reading leaves the secondary signal out of the decision instead of
    /// standing in for it with a zero or, worse, with the whole process.
    public mutating func evaluate(
        coalescenceRate      : Double,
        attributableCpuPercent: Double? = nil
    ) -> MonitorQualityChange? {

        coalescenceReadings = coalescenceRate > Self.coalescenceLimit ? coalescenceReadings + 1 : 0
        if let attributableCpuPercent {
            let limit   = Self.cpuPercentLimit(at: quality.frameRate)
            cpuReadings = attributableCpuPercent > limit ? cpuReadings + 1 : 0
        } else {
            cpuReadings = 0
        }

        let reason: MonitorDegradationReason
        if coalescenceReadings >= Self.readingsToDegrade {
            reason = .coalescence(rate: coalescenceRate)
        } else if cpuReadings >= Self.readingsToDegrade, let attributableCpuPercent {
            reason = .cpuCost(percent: attributableCpuPercent)
        } else {
            return nil
        }

        // At the floor the counters are cleared anyway: leaving them to grow
        // would mean the next reading over the limit fires an event for a
        // change that cannot happen.
        coalescenceReadings = 0
        cpuReadings         = 0
        guard let degraded = quality.degraded() else { return nil }

        let change = MonitorQualityChange(from: quality, to: degraded, reason: reason)
        quality = degraded
        return change
    }
}

//
//  MonitorQualityPolicyTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation
@testable import SeatCapture
import Testing

@Suite("The degradation ladder")
struct MonitorQualityTests {

    @Test("frames go first, all the way down, and only then resolution")
    func theLadder() {
        var quality = MonitorQuality(frameRate: .oneHundredTwenty)
        var rungs: [MonitorQuality] = [quality]
        while let next = quality.degraded() {
            quality = next
            rungs.append(next)
        }

        #expect(rungs == [
            MonitorQuality(frameRate: .oneHundredTwenty, resolutionScale: 1),
            MonitorQuality(frameRate: .sixty,            resolutionScale: 1),
            MonitorQuality(frameRate: .thirty,           resolutionScale: 1),
            MonitorQuality(frameRate: .thirty,           resolutionScale: 0.5),
        ])
        #expect(rungs.last?.degraded() == nil, "the floor answers nil instead of cutting further")
    }

    @Test("the default is 60 fps at full resolution")
    func standardRung() {
        #expect(MonitorQuality.standard == MonitorQuality(frameRate: .sixty, resolutionScale: 1))
        #expect(MonitorConfiguration(output: .fixed(CGSize(width: 8, height: 8))).targetFrameRate == .sixty)
    }

    @Test("a rung asks the stream for its own share of the configured size")
    func rungPixelSize() {
        let configured = CGSize(width: 1920, height: 1080)
        #expect(MonitorQuality(frameRate: .sixty).pixelSize(from: configured) == configured)
        #expect(
            MonitorQuality(frameRate: .thirty, resolutionScale: 0.5).pixelSize(from: configured)
                == CGSize(width: 960, height: 540)
        )
        // A size that would round to zero is clamped: a stream of no pixels is
        // not a smaller stream, it is a refusal.
        #expect(
            MonitorQuality(frameRate: .thirty, resolutionScale: 0.5)
                .pixelSize(from: CGSize(width: 1, height: 1)) == CGSize(width: 1, height: 1)
        )
    }
}

@Suite("The quality policy on synthetic readings")
struct MonitorQualityPolicyTests {

    /// Feeds a series of coalescence rates and returns the changes it produced.
    private func run(
        coalescence: [Double],
        from quality: MonitorQuality = .standard
    ) -> (changes: [MonitorQualityChange], final: MonitorQuality) {
        var policy = MonitorQualityPolicy(quality: quality)
        var changes: [MonitorQualityChange] = []
        for rate in coalescence {
            if let change = policy.evaluate(coalescenceRate: rate) { changes.append(change) }
        }
        return (changes, policy.quality)
    }

    @Test("a clean series never degrades")
    func cleanSeries() {
        let outcome = run(coalescence: Array(repeating: 0, count: 20))
        #expect(outcome.changes.isEmpty)
        #expect(outcome.final == .standard)
    }

    @Test("a series exactly at the budget never degrades")
    func atTheBudget() {
        // One percent is the budget of spec section 8, and a budget is what is
        // still allowed: the comparison has to be strictly greater.
        let outcome = run(coalescence: Array(repeating: MonitorQualityPolicy.coalescenceLimit, count: 10))
        #expect(outcome.changes.isEmpty)
    }

    @Test("one bad reading is not enough, two in a row are")
    func twoReadingsRule() {
        let single = run(coalescence: [0.5, 0, 0.5, 0, 0.5])
        #expect(single.changes.isEmpty, "a spike every other second is the machine, not the Monitor")

        let sustained = run(coalescence: [0.5, 0.5])
        #expect(sustained.changes.count == 1)
        #expect(sustained.final == MonitorQuality(frameRate: .thirty))
        #expect(sustained.changes.first?.reason == .coalescence(rate: 0.5))
        #expect(sustained.changes.first?.from == .standard)
    }

    @Test("a level change resets the count, so the new rung is judged on its own evidence")
    func changeResetsTheCount() {
        // Four bad readings from 60 fps: two degrade to 30, the next two degrade
        // to half resolution, and there is no third change from four readings.
        let outcome = run(coalescence: [1, 1, 1, 1])
        #expect(outcome.changes.count == 2)
        #expect(outcome.final == MonitorQuality(frameRate: .thirty, resolutionScale: 0.5))
    }

    @Test("the floor stops the ladder without emitting an event for a change that cannot happen")
    func floorIsSilent() {
        let outcome = run(
            coalescence: Array(repeating: 1, count: 10),
            from       : MonitorQuality(frameRate: .thirty, resolutionScale: 0.5)
        )
        #expect(outcome.changes.isEmpty)
        #expect(outcome.final == MonitorQuality(frameRate: .thirty, resolutionScale: 0.5))
    }

    @Test("the attributable CPU alone degrades, and says so as the reason")
    func cpuIsTheSecondarySignal() {
        var policy = MonitorQualityPolicy()
        #expect(policy.evaluate(coalescenceRate: 0, attributableCpuPercent: 30) == nil)
        let change = policy.evaluate(coalescenceRate: 0, attributableCpuPercent: 30)
        #expect(change?.reason == .cpuCost(percent: 30))
        #expect(policy.quality == MonitorQuality(frameRate: .thirty))
    }

    @Test("an attributable cost inside the budget does not degrade")
    func cpuInsideBudget() {
        var policy = MonitorQualityPolicy()
        for _ in 0..<10 {
            #expect(policy.evaluate(coalescenceRate: 0, attributableCpuPercent: 6.2) == nil)
        }
        // 6,2 % is the measured cost of the zero-copy pipeline at 1920x1080
        // and 60 fps: the pipeline the kit ships must not degrade
        // itself on its own measured cost.
        #expect(policy.quality == .standard)
    }

    @Test("coalescence wins the tie, because it is the signal taken inside the pipeline")
    func coalescenceHasPriority() {
        var policy = MonitorQualityPolicy()
        _ = policy.evaluate(coalescenceRate: 0.5, attributableCpuPercent: 90)
        let change = policy.evaluate(coalescenceRate: 0.5, attributableCpuPercent: 90)
        #expect(change?.reason == .coalescence(rate: 0.5))
    }

    @Test("a missing CPU reading is not a zero and not a failure")
    func missingCpuReading() {
        var policy = MonitorQualityPolicy()
        // A consumer without a heartbeat still gets coalescence-driven
        // degradation, and nothing stands in for the reading it does not have.
        _ = policy.evaluate(coalescenceRate: 0.2, attributableCpuPercent: nil)
        let change = policy.evaluate(coalescenceRate: 0.2, attributableCpuPercent: nil)
        #expect(change?.reason == .coalescence(rate: 0.2))
    }

    @Test("the ladder does not climb back on its own")
    func noRecovery() {
        var policy = MonitorQualityPolicy()
        _ = policy.evaluate(coalescenceRate: 1)
        _ = policy.evaluate(coalescenceRate: 1)
        #expect(policy.quality == MonitorQuality(frameRate: .thirty))

        for _ in 0..<30 {
            #expect(policy.evaluate(coalescenceRate: 0, attributableCpuPercent: 0) == nil)
        }
        #expect(policy.quality == MonitorQuality(frameRate: .thirty))
    }
}

@Suite("What the consumer configures")
struct MonitorConfigurationTests {

    @Test("backing output maps one captured pixel to one pixel of the view")
    func backingSize() {
        let configuration = MonitorConfiguration(
            output: .backing(pointSize: CGSize(width: 960, height: 540), scale: 2)
        )
        #expect(configuration.output.pixelSize == CGSize(width: 1920, height: 1080))
        #expect(configuration.captureConfiguration(for: configuration.quality).framesPerSecond == 60)
    }

    @Test("a scale under one is treated as one rather than shrinking the capture")
    func degenerateScale() {
        let configuration = MonitorConfiguration(
            output: .backing(pointSize: CGSize(width: 384, height: 216), scale: 0)
        )
        #expect(configuration.output.pixelSize == CGSize(width: 384, height: 216))
    }

    @Test("fixed output is taken as given, rounded to whole pixels")
    func fixedSize() {
        let configuration = MonitorConfiguration(
            targetFrameRate: .thirty,
            output         : .fixed(CGSize(width: 960.4, height: 540.6))
        )
        #expect(configuration.output.pixelSize == CGSize(width: 960, height: 541))
        #expect(configuration.captureConfiguration(for: configuration.quality).framesPerSecond == 30)
    }

    @Test("a degraded rung reconfigures both size and pace")
    func degradedRung() {
        let configuration = MonitorConfiguration(
            output: .backing(pointSize: CGSize(width: 960, height: 540), scale: 2)
        )
        let capture = configuration.captureConfiguration(
            for: MonitorQuality(frameRate: .thirty, resolutionScale: 0.5)
        )
        #expect(capture.pixelSize       == CGSize(width: 960, height: 540))
        #expect(capture.framesPerSecond == 30)
    }
}

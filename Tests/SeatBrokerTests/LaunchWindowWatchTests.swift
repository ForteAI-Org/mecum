//
//  LaunchWindowWatchTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

import CoreGraphics
@testable import SeatBroker
import Testing

/// DaVinci Resolve's cold start in the background, as measured on 29/09/2026,
/// replayed at the 300 ms `launch` reads at.
@Suite("Waiting for a launched application's first window")
struct LaunchWindowWatchTests {

    static let splash  = TargetWindow(pid: 1, windowNumber: 76_126, title: "", frame: CGRect(x: 0, y: 0, width: 1110, height: 490))
    static let manager = TargetWindow(pid: 1, windowNumber: 76_230, title: "Project Manager", frame: CGRect(x: 0, y: 0, width: 910, height: 640))

    /// Replays readings until a verdict other than waiting, and answers it with its time.
    static func replay(
        until end: Double = 70,
        _ reading: (Double) -> (shown: [TargetWindow], named: Set<Int>)
    ) -> (verdict: LaunchWindowWatch.Verdict, at: Double) {
        var watch = LaunchWindowWatch(timeout: .seconds(20), allowance: .seconds(60))
        var time = 0.0
        while time <= end {
            let (shown, named) = reading(time)
            let verdict = watch.read(shown: shown, named: named, at: .milliseconds(Int(time * 1000)))
            if verdict != .wait { return (verdict, time) }
            time += 0.3
        }
        return (.wait, time)
    }

    @Test("a splash accessibility names for an instant is never taken, and the Project Manager is")
    func theSplashIsNotTaken() {
        let (verdict, at) = Self.replay { time in
            switch time {
                case ..<1.7: ([], [])
                case ..<2.1: ([Self.splash], [Self.splash.windowNumber])
                case ..<6.6: ([Self.splash], [])
                default:     ([Self.manager], [Self.manager.windowNumber])
            }
        }
        #expect(verdict == .adopt([Self.manager]))
        #expect(at >= 7.5 && at < 8.5)
    }

    @Test("a start that showed a splash keeps its allowance after the splash is gone")
    func theAllowanceOutlivesTheSplash() {
        let (verdict, at) = Self.replay { time in
            switch time {
                case ..<1.7:  ([], [])
                case ..<6.8:  ([Self.splash], [])
                case ..<24.8: ([], [])
                default:      ([Self.manager], [Self.manager.windowNumber])
            }
        }
        #expect(verdict == .adopt([Self.manager]))
        #expect(at > 24.8)
    }

    @Test("an application that shows nothing times out at the first deadline")
    func nothingShownTimesOut() {
        let (verdict, at) = Self.replay { _ in ([], []) }
        #expect(verdict == .timedOut(shown: []))
        #expect(at >= 20 && at < 20.5)
    }
}

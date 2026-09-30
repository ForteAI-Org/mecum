//
//  LaunchWindowWatch.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

/// LaunchWindowWatch decides, one reading at a time, when an application this
/// broker launched shows a window the seat can take.
///
/// Measured with DaVinci Resolve launched in the background on 29/09/2026:
/// accessibility named its untitled splash for a few tenths of a second, at
/// 1.7 s, and the seat was handed that window and failed on it; the splash
/// left at 6.8 s, and the Project Manager stood at window level 4 until 24.8 s,
/// while Resolve kept itself active. So a window counts only once
/// accessibility has named it for `stableFor`, and a start that showed
/// anything keeps the startup allowance after that window is gone.
struct LaunchWindowWatch {

    enum Verdict: Equatable {
        case wait
        case adopt([TargetWindow])
        /// The time ran out; `shown` is what was on screen then, possibly nothing.
        case timedOut(shown: [TargetWindow])
    }

    static let stableFor: Duration = .seconds(1)

    let timeout  : Duration
    let allowance: Duration

    private var sawWindow  = false
    private var namedSince: [Int: Duration] = [:]

    init(timeout: Duration, allowance: Duration) {
        self.timeout   = timeout
        self.allowance = allowance
    }

    mutating func read(shown: [TargetWindow], named: Set<Int>, at elapsed: Duration) -> Verdict {
        if !shown.isEmpty { sawWindow = true }
        let adoptable = shown.filter { named.contains($0.windowNumber) }
        namedSince = namedSince.filter { number, _ in adoptable.contains { $0.windowNumber == number } }
        for window in adoptable where namedSince[window.windowNumber] == nil {
            namedSince[window.windowNumber] = elapsed
        }
        let stable = adoptable.filter { elapsed - (namedSince[$0.windowNumber] ?? elapsed) >= Self.stableFor }
        if !stable.isEmpty { return .adopt(stable) }
        return elapsed >= (sawWindow ? max(timeout, allowance) : timeout) ? .timedOut(shown: shown) : .wait
    }
}

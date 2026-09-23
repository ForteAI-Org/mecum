//
//  MainThreadProbe.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// MainThreadProbe measures how long the main thread goes without serving
/// its queue (§20.2: no block over 100 ms).
///
/// A timer on its own queue posts a stamped block to the main queue every
/// `interval`; each block records how late it ran. The main actor runs its
/// jobs from that queue, so a lateness is a span in which the main thread
/// was busy with something else, and the largest is the longest block, to
/// within one interval.
///
/// With `work`, each block runs it before reading the time, so a lateness is
/// the wait and the work together: a keystroke delivered and laid out.
///
/// Main actor isolated. `start` and `stop` bracket one measurement; the timer
/// is cancelled by `stop` and holds the probe only weakly.
@MainActor
final class MainThreadProbe {

    private(set) var lateness: [Double] = []
    private var timer: (any DispatchSourceTimer)?

    func start(interval: Duration = .milliseconds(2), work: (@MainActor @Sendable () -> Void)? = nil) {
        lateness = []
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mecum.bench.probe"))
        let period = Int(BenchmarkRecord.milliseconds(interval) * 1000)
        source.schedule(deadline: .now(), repeating: .microseconds(period))
        source.setEventHandler(handler: Self.post(to: self, work: work))
        source.resume()
        timer = source
    }

    /// The timer's handler, made outside the main actor: a closure formed in a
    /// main actor method would check that isolation on the timer's queue and trap.
    private nonisolated static func post(
        to probe: MainThreadProbe,
        work    : (@MainActor @Sendable () -> Void)?
    ) -> @Sendable () -> Void {
        { [weak probe] in
            let sent = ContinuousClock.now
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    work?()
                    probe?.lateness.append(BenchmarkRecord.milliseconds(ContinuousClock.now - sent))
                }
            }
        }
    }

    /// Stops posting and returns the latenesses recorded, in milliseconds.
    func stop() -> BenchmarkRecord.Samples {
        timer?.cancel()
        timer = nil
        return BenchmarkRecord.Samples(lateness)
    }
}

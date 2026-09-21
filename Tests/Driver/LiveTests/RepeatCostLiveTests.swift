//
//  RepeatCostLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing

/// The two open measurements of ticket A3.
///
/// `KeyPhase.maximumRepeatCount` is 32 because 32 repeats at the system's own
/// interval hold a target's exclusion for about a second, which is a reasoning
/// about cost and not a measurement of what a target tolerates. And the pause
/// between repeats is dead time this process spends inside an uninterruptible
/// `usleep`, holding the PID exclusion for every other driver.
///
/// Both questions are answered by the same sweep, which is why they are one
/// suite. The probe page counts every `keydown` it receives in `k`, so a run of
/// `n` repeats should move it by `n + 1`: the down, then the repeats. Anything
/// less is the target dropping them.
///
/// **The cheap question comes first.** If a zero interval delivers every repeat,
/// the dead time is unnecessary and there is nothing to optimise: the
/// experiment with spaced event timestamps, which would exist only to remove a
/// pause that turned out not to be needed, never has to be written.
@MainActor
struct RepeatCostLiveTests {

    /// A platform whose repeat pacing is the sweep's, and whose preparation is
    /// nothing: a key Command needs none on either family.
    struct PacedPlatform: InputPlatform {
        let pacing: KeyRepeatPacing
        func preparation(for command: InputCommand) -> Preparation { .none }
        var keyRepeatPacing: KeyRepeatPacing { pacing }
    }

    /// The counts to try. The last is the cap as it stands, so a run says
    /// whether the cap is conservative, right, or already too generous.
    static let counts = [1, 4, 16, KeyPhase.maximumRepeatCount]

    /// The intervals to try, in microseconds. Zero is the question that makes
    /// the rest moot if it passes; 33000 is the system's own.
    static let intervals: [UInt32] = [0, 8_000, 33_000]

    @Test("how many repeats a target actually receives, and at what pacing",
          .enabled(if: liveSkipReason(needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(needsChrome: true) ?? "")))
    func theRepeatSweep() async throws {
        try await LiveStage.run(needsFixture: FixtureTarget.isAvailable) { stage in
            for target in stage.targets {
                try await Self.sweep(on: stage, target: target)
            }
        }
    }

    private static func sweep(on stage: LiveStage, target: any MatrixTarget) async throws {
        let chrome = target
        let window = try await adopt(target, onto: stage.seat, bounds: stage.virtualBounds)
        let arrow  = Shortcut.physical(PhysicalKey(name: "ArrowRight", virtualKey: 124))
        print("\n=== \(target.name) ===")

        print("\n| interval us | asked | down | repeats | dead time ms |")
        var rows: [(interval: UInt32, asked: Int, repeats: Int)] = []

        /// Sends one phase, reads what the target counted for it, and confirms
        /// that Command with what its own delta said.
        ///
        /// Read per send and not once at the end, for two reasons. A Turn
        /// cannot be given back while a Command it posted is unconfirmed, which
        /// is the anti replay invariant; and a single delta across three sends
        /// could not say whether a shortfall was the down that never registered
        /// or the repeats that were dropped.
        func measure(
            _ phase : KeyPhase,
            turn    : Turn,
            platform: any InputPlatform
        ) async throws -> Int {
            let before  = chrome.state()["keyDowns"] ?? 0
            let receipt = try await stage.seat.send(
                arrow,
                phase      : phase,
                observation: try await liveObservation(stage.seat),
                turn       : turn,
                platform   : platform
            )
            LivePump.run(for: 0.25)
            let delta = Int((chrome.state()["keyDowns"] ?? 0) - before)
            try stage.seat.confirm(receipt, delta > 0 ? .observed : .absent)
            return delta
        }

        for interval in Self.intervals {
            let platform = PacedPlatform(pacing: KeyRepeatPacing(intervalMicroseconds: interval))
            for asked in Self.counts {
                let turn    = try await stage.seat.acquire()
                let started = DispatchTime.now().uptimeNanoseconds

                let down    = try await measure(.down, turn: turn, platform: platform)
                let repeats = try await measure(.repeated(count: asked), turn: turn, platform: platform)
                // The key up is counted too, and is expected to move nothing:
                // the page listens for `keydown` only.
                _ = try await measure(.up, turn: turn, platform: platform)

                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                rows.append((interval, asked, repeats))
                print(String(
                    format: "| %11u | %5d | %4d | %7d | %12.0f |",
                    interval, asked, down, repeats, Double(elapsed) / 1e6
                ))
                try stage.seat.release(turn)
            }
        }

        // The repeats are counted on their own now, so the expected figure is
        // the count asked for and nothing else.
        for row in rows where row.interval == 33_000 {
            #expect(
                row.repeats == row.asked,
                Comment(rawValue: "at the system interval, \(row.asked) repeats arrived as "
                    + "\(row.repeats): the target dropped some, so the cap is not the only "
                    + "thing bounding a repeat")
            )
        }

        // Ordinary presses provide a delivery control independent of repeat pacing.
        let control = try await stage.seat.acquire()
        var ordinary = 0
        let unpaced  = PacedPlatform(pacing: KeyRepeatPacing(intervalMicroseconds: 0))
        for _ in 0 ..< 4 {
            ordinary += try await measure(.press, turn: control, platform: unpaced)
        }
        try stage.seat.release(control)
        print("control: 4 ordinary presses arrived as \(ordinary)")

        #expect(ordinary == 4, "The ordinary-press control must receive all four presses")
        let pacingMatters = Self.counts.contains { asked in
            Set(rows.filter { $0.asked == asked }.map(\.repeats)).count > 1
        }
        print("repeats received: \(rows.map(\.repeats)) for counts "
            + "\(rows.map(\.asked)) across intervals \(Self.intervals). Ordinary presses in "
            + "the control: \(ordinary) of 4. Pacing changed the outcome: \(pacingMatters).")

        await stage.giveBack(window, of: target, home: stage.home(of: target))
    }
}

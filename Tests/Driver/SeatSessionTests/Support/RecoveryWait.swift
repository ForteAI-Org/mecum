//
//  RecoveryWait.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import Foundation
@testable import SeatSession

/// What a wait on the recovery loop measured, so a row that did not see its
/// condition says which of the two things happened.
///
/// A recovery row waits for something the loop reaches on its own cadence, and
/// there are two reasons it may not arrive. The loop was starved, because every
/// suite in this tier shares one main actor and the loop's sleeps then cost far
/// more than they ask for; or the recovery really did not reach the state, which
/// is a defect. A boolean cannot tell them apart, and the usual answer to that
/// is a larger timeout, which hides both.
///
/// The three numbers do tell them apart. `elapsed` is the wall clock the wait
/// spent. `unreadable` is what the plan itself measured, which is the budget the
/// loop is judged on. `readings` is how many laps that took. Starvation is a
/// large elapsed with few readings; a defect is a spent budget with the
/// condition still false.
@MainActor
struct RecoveryWait: CustomStringConvertible {

    let satisfied          : Bool
    let elapsedNanoseconds : UInt64

    /// The plan the loop published, and nil when it published none at all:
    /// zero readings on a plan that exists and no plan are different facts,
    /// and only the second one says the task never reached its loop.
    let progress: WindowRecoveryPlan?

    var unreadableNanoseconds: UInt64 { progress?.unreadableNanoseconds ?? 0 }
    var readings             : Int    { progress?.readings ?? 0 }

    /// Waits for the condition, reading the seat's own recovery measurements
    /// as it goes. It sleeps and never pumps, like every other wait in this
    /// tier: pumping here would hold the actor the loop needs.
    static func settle(
        _ seat        : AgentSeat,
        until condition: @MainActor () -> Bool,
        within seconds: Double = 60,
        interval      : Duration = .milliseconds(50)
    ) async -> RecoveryWait {

        ProcessKeepAlive.start()

        let started  = DispatchTime.now().uptimeNanoseconds
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            if condition() { break }
            await EventLoopWait.sleep(interval)
        }

        return RecoveryWait(
            satisfied         : condition(),
            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
            progress          : seat.recoveryProgress
        )
    }

    var description: String {

        guard !satisfied else { return "satisfied" }

        let wall = "not satisfied after \(Self.milliseconds(elapsedNanoseconds)) ms of wall clock"

        guard let progress else {
            return wall + ", with no recovery plan published at all: the loop never reached "
                + "its first reading, which is a starved main actor and not a budget"
        }

        return """
            \(wall), with the recovery measuring \
            \(Self.milliseconds(progress.unreadableNanoseconds)) ms unreadable and \
            \(Self.milliseconds(progress.elapsedNanoseconds)) ms of its own episode over \
            \(progress.readings) readings. A wall clock far above the measured time with \
            few readings is a starved main actor; a measured time past the plan's own \
            limit with the condition still false is a defect in the recovery
            """
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> UInt64 { nanoseconds / 1_000_000 }
}

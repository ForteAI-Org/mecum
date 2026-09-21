//
//  TextCeilingLiveTests.swift
//  AgentSeatFixture
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing

/// What one `.insertText` really carries, and what it costs.
///
/// `TextLimits.maximumInsertedCodeUnits` is 8192 because that is where the
/// evidence stopped, on a build that is no longer the one installed. This sweep
/// asks the same question of 26A428: does the declared ceiling still arrive
/// whole, on both families, and what does each step cost.
///
/// It does **not** hunt for the length where delivery breaks. It cannot: the
/// driver refuses above the ceiling, which is the contract, and finding a
/// higher break point means raising the constant on purpose and running again.
/// That is a deliberate research step and not something a suite should do
/// behind the reader's back. What this closes is the other half: the ceiling
/// the kit declares is one it can actually deliver, and the refusal above it
/// happens.
@MainActor
struct TextCeilingLiveTests {

    /// Powers of two up to the declared ceiling. ASCII, so a code unit and a
    /// keystroke are the same thing and the two units cannot be confused while
    /// reading the table.
    static let lengths = [512, 1024, 2048, 4096, TextLimits.maximumInsertedCodeUnits]

    @Test("the declared text ceiling still arrives whole, and costs what it costs",
          .timeLimit(.minutes(5)),
          .enabled(if: liveSkipReason(needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(needsChrome: true) ?? "")))
    func theTextCeilingSweep() async throws {
        try await LiveStage.run(needsFixture: FixtureTarget.isAvailable) { stage in
            for target in stage.targets {
                try await Self.sweep(on: stage, target: target)
            }
        }
    }

    private static func sweep(on stage: LiveStage, target: any MatrixTarget) async throws {
        let window = try await adopt(target, onto: stage.seat, bounds: stage.virtualBounds)
        print("\n=== \(target.name) ===")
        print("| code units | arrived | ms | us per unit |")

        for length in Self.lengths {
            let text   = String(repeating: "a", count: length)
            let turn   = try await stage.seat.acquire()
            let before = try #require(target.state()["field"], "The initial field counter is unreadable")

            let started = DispatchTime.now().uptimeNanoseconds
            let receipt = try await stage.seat.send(
                .insertText(text),
                observation: try await liveObservation(stage.seat),
                turn       : turn
            )
            let posted  = DispatchTime.now().uptimeNanoseconds - started

            // Polled rather than slept: a long insertion lands when it lands,
            // and a fixed wait would either be too short for the ceiling or
            // waste seconds on every shorter row.
            _ = LivePump.run(
                until  : { target.state()["field"].map { $0 - before >= Double(length) } ?? false },
                timeout: 20
            )
            let after = try #require(target.state()["field"], "The resulting field counter is unreadable")
            let arrived = Int(after - before)

            try stage.seat.confirm(receipt, arrived > 0 ? .observed : .absent)
            try stage.seat.release(turn)

            print(String(
                format: "| %10d | %7d | %4.0f | %11.1f |",
                length, arrived, Double(posted) / 1e6,
                Double(posted) / 1e3 / Double(length)
            ))
            #expect(
                arrived == length,
                Comment(rawValue: "\(target.name): \(length) code units arrived as \(arrived), "
                    + "so the declared ceiling is not one this build delivers whole")
            )
            // The receipt counts the units it posted, in the unit that Command
            // counts in, which is the whole point of `TextMeasure`.
            #expect(receipt.textMeasure == TextMeasure(length, .utf16CodeUnits))
            #expect(receipt.eventCount == 2, "an insertion is two events at any length")

            // Emptied between rows, so each one measures its own delivery and
            // not the sum of everything before it.
            try await Self.clearField(of: target, stage: stage, window: window)
        }

        // The contract above the ceiling: refused, and refused before anything
        // is posted.
        //
        // The error is not always a bare `InputFailure`. On a platform that
        // prepares for an insertion the refusal happens after the Preparation,
        // so it arrives wrapped in an `InputPreparationFailure` that also says
        // the Preparation was given back. Both are the same refusal and the
        // wrapper carries more, not less.
        let turn = try await stage.seat.acquire()
        let tooLong = String(repeating: "a", count: TextLimits.maximumInsertedCodeUnits + 1)
        var refused = false
        do {
            _ = try await stage.seat.send(
                .insertText(tooLong),
                observation: try await liveObservation(stage.seat),
                turn       : turn
            )
        } catch let failure as InputPreparationFailure {
            refused = failure.cause is InputFailure
            #expect(failure.progress.cleanup == .succeeded, "the Preparation was not given back")
        } catch is InputFailure {
            refused = true
        }
        #expect(refused, "\(target.name) accepted a Command above the declared ceiling")
        try stage.seat.release(turn)

        await stage.giveBack(window, of: target, home: stage.home(of: target))
    }

    /// Selects everything and deletes it, through the two shortcuts that were
    /// measured to work on the responder chain rather than through a menu.
    private static func clearField(
        of target: any MatrixTarget,
        stage    : LiveStage,
        window   : AdoptedWindow
    ) async throws {
        let turn = try await stage.seat.acquire()
        // Command and A is a menu equivalent and does not work here, which
        // ticket A8 measured. Backspace held down is the responder chain's own
        // answer, and a repeat is what makes it practical.
        let backspace = Shortcut.physical(PhysicalKey(name: "Backspace", virtualKey: 51))
        let receipts = [
            try await stage.seat.send(
                backspace,
                phase      : .down,
                observation: try await liveObservation(stage.seat),
                turn       : turn
            ),
            try await stage.seat.send(
                backspace,
                phase      : .repeated(count: KeyPhase.maximumRepeatCount),
                observation: try await liveObservation(stage.seat),
                turn       : turn
            ),
            try await stage.seat.send(
                backspace,
                phase      : .up,
                observation: try await liveObservation(stage.seat),
                turn       : turn
            ),
        ]
        for receipt in receipts { try stage.seat.confirm(receipt, .unknown) }
        try stage.seat.release(turn)
        LivePump.run(for: 0.3)
    }
}

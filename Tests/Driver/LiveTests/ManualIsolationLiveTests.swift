//
//  ManualIsolationLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing

/// The two rows that need a hand on the keyboard.
///
/// Every other Live row treats a hand on the machine as contamination and
/// reports `INCO` when the fence saw physical events. These two need exactly
/// that hand, which is why they are behind their own switch and never run in
/// the same pass: each would ruin the other.
///
/// What they measure is the claim `CGEventSource(stateID: .privateState)` makes
/// and that nothing has ever checked: that the person's own modifier state
/// stays out of the kit's events, and the kit's stays out of the person's. The
/// source's documentation says so; a documented intention is not a measurement.
@MainActor
struct ManualIsolationLiveTests {

    /// A platform that posts real modifier transitions, for the one row that is
    /// about what a transition leaves behind.
    struct TransitionPlatform: InputPlatform {
        func preparation(for command: InputCommand) -> Preparation { .none }
        func modifierPolicy(for command: InputCommand) -> ModifierPolicy { .flagsChanged }
    }

    static let command = Shortcut.physical(PhysicalKey(name: "MetaLeft", virtualKey: 55))
    static let letter  = Shortcut.character("c")

    /// Pumps while the person does what they were asked, and says whether the
    /// **hardware** ever showed the key they were asked for.
    ///
    /// Without it these two rows have no oracle and pass vacuously: a person
    /// who never touched the keyboard produces exactly the reading a person who
    /// held the key and was kept out of the event produces, which is zero. The
    /// state is read from `hidSystemState`, the physical keyboard's own, so the
    /// kit's events cannot appear in it whatever they carry: that is what makes
    /// the answer about the person.
    @discardableResult
    static func watchThePerson(
        _ instruction: String,
        seconds      : Double,
        for flags    : CGEventFlags
    ) -> Bool {
        print("\n  ===> \(instruction)")
        print("      (\(Int(seconds)) seconds)")
        var seen     = false
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if CGEventSource.flagsState(.hidSystemState).contains(flags) { seen = true }
            LivePump.run(for: 0.05)
        }
        return seen
    }

    /// Says what will be asked **before** the stage comes up.
    ///
    /// Everything else in this tier prints for a reader afterwards; these two
    /// rows print for a person who is sitting there now. A prompt that appears
    /// after twenty seconds of window server work, with six seconds to react to
    /// it, is a row whose answer depends on how fast somebody reads.
    static func announce(_ steps: [String]) {
        print("\n  ==== a row that needs your hands ====")
        for (index, step) in steps.enumerated() {
            print("  \(index + 1). \(step)")
        }
        print("  the stage takes about twenty seconds to come up first.\n")
    }

    @Test("the person's own held modifier stays out of the kit's events",
          .enabled(if: manualTestsEnabled() && liveSkipReason(needsChrome: true) == nil,
                   Comment(rawValue: "needs AGENTSEAT_MANUAL_TESTS=1 and a person at the keyboard")))
    func thePersonsModifiersDoNotLeakIn() async throws {
        Self.announce([
            "when you are told to, hold SHIFT down and keep holding it",
            "let SHIFT go when you are told to, and take your hands off",
        ])
        try await LiveStage.run(needsFixture: false) { stage in
            try await Self.measureIncomingLeak(on: stage)
        }
    }

    private static func measureIncomingLeak(on stage: LiveStage) async throws {
        let chrome = try #require(stage.chrome, "this row reads the probe page's own report")
        let window = try await adopt(chrome, onto: stage.seat, bounds: stage.virtualBounds)
        let turn   = try await stage.seat.acquire()

        let held = Self.watchThePerson(
            "hold SHIFT down and keep holding it until you are told to let go",
            seconds: 10,
            for    : .maskShift
        )
        // Read at the instant of the post, not only during the window: what the
        // row is about is the state of the hardware while this event went out.
        let heldAtThePost = CGEventSource.flagsState(.hidSystemState).contains(.maskShift)

        let receipt = try await stage.seat.send(
            Self.letter,
            observation: try await liveObservation(stage.seat),
            turn       : turn
        )
        LivePump.run(for: 0.5)
        let observed = chrome.state()["lastModifiers"]
        try stage.seat.confirm(receipt, observed == nil ? .unknown : .observed)

        askThePerson("let SHIFT go, hands off", seconds: 5)

        let reading = observed.map { value in "\(value)" } ?? "unreadable"
        print("the target saw modifiers \(reading) while the person held shift "
            + "(hardware: seen \(held), still down at the post \(heldAtThePost))")

        if observed == nil {
            Issue.record(Comment(rawValue: "the target published no modifier mask, "
                + "so nothing is concluded"))
            try stage.seat.release(turn)
            await stage.giveBack(window, of: chrome, home: stage.chromeHome)
            return
        }
        guard heldAtThePost else {
            // Zero is also what an untouched keyboard produces. A row that read
            // it without this check would report the isolation working on a run
            // where nothing was ever held, which is the instrument answering
            // for the system.
            Issue.record(Comment(rawValue: "nobody was holding shift when the event went out, "
                + "so the zero below is about an idle keyboard and not about isolation"))
            try stage.seat.release(turn)
            await stage.giveBack(window, of: chrome, home: stage.chromeHome)
            return
        }
        // The whole isolation claim in one number. A private event source is
        // documented not to carry the person's state; this is the first thing
        // that checks it against a real hand.
        #expect(
            observed == 0,
            Comment(rawValue: "the kit's event carried \(reading) while the person held shift: "
                + "the private event source did not keep their state out")
        )

        try stage.seat.release(turn)
        await stage.giveBack(window, of: chrome, home: stage.chromeHome)
    }

    @Test("a transition the kit never released is cleared by the person's own key",
          .enabled(if: manualTestsEnabled() && liveSkipReason(needsChrome: true) == nil,
                   Comment(rawValue: "needs AGENTSEAT_MANUAL_TESTS=1 and a person at the keyboard")))
    func aStrandedTransitionIsClearedByTheHardware() async throws {
        Self.announce([
            "wait, with your hands off the keyboard, until you are told",
            "then press and release the COMMAND key once, and take your hands off again",
        ])
        try await LiveStage.run(needsFixture: false) { stage in
            try await Self.measureStrandedTransition(on: stage)
        }
    }

    private static func measureStrandedTransition(on stage: LiveStage) async throws {
        let chrome   = try #require(stage.chrome, "this row reads the probe page's own report")
        let window   = try await adopt(chrome, onto: stage.seat, bounds: stage.virtualBounds)
        let turn     = try await stage.seat.acquire()
        let platform = TransitionPlatform()

        // Command goes down as a real transition and is deliberately not
        // released: this is the failure mode ADR 0011 is written about, and the
        // question is whether the target digs itself out of it.
        var receipts = [
            try await stage.seat.send(
                Self.command,
                phase      : .down,
                observation: try await liveObservation(stage.seat),
                turn       : turn,
                platform   : platform
            )
        ]
        LivePump.run(for: 0.3)

        receipts.append(
            try await stage.seat.send(
                Self.letter,
                observation: try await liveObservation(stage.seat),
                turn       : turn,
                platform   : platform
            )
        )
        LivePump.run(for: 0.4)
        let whileStranded = chrome.state()["lastModifiers"]

        let pressed = Self.watchThePerson(
            "press and release the COMMAND key once, then take your hands off",
            seconds: 10,
            for    : .maskCommand
        )

        receipts.append(
            try await stage.seat.send(
                Self.letter,
                observation: try await liveObservation(stage.seat),
                turn       : turn,
                platform   : platform
            )
        )
        LivePump.run(for: 0.4)
        let afterTheHardware = chrome.state()["lastModifiers"]

        let before = whileStranded.map { value in "\(value)" } ?? "unreadable"
        let after  = afterTheHardware.map { value in "\(value)" } ?? "unreadable"
        print("""

            === a transition the kit never released, \(chrome.name) ===
            | command bit while stranded | after the person's own command | hardware saw it |
            | \(before) | \(after) | \(pressed) |
            """)

        // No expectation either way, and no Issue either: both answers are a
        // real one. A target that clears itself makes a stranded modifier self
        // healing, and a target that does not makes it permanent until the kit
        // posts the release. Asserting the answer we would prefer turns a
        // measurement into a wish, and recording an Issue for a row that did
        // exactly what it was written to do turns a ledger line into a failure.
        if !pressed {
            Issue.record(Comment(rawValue: "the hardware never showed command during the "
                + "window, so the second reading is not about the person's key"))
        }

        receipts.append(
            try await stage.seat.send(
                Self.command,
                phase      : .up,
                observation: try await liveObservation(stage.seat),
                turn       : turn,
                platform   : platform
            )
        )
        // The Turn refuses to be given back while a Command it handed out is
        // unaccounted for, which is the anti replay rule and is why both of
        // these rows failed on their first real run: they measured, printed,
        // and then dropped four receipts on the floor.
        for receipt in receipts { try stage.seat.confirm(receipt, .unknown) }
        try stage.seat.release(turn)
        await stage.giveBack(window, of: chrome, home: stage.chromeHome)
    }
}

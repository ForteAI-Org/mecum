//
//  TextCompositionLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing

/// What an `.insertText` does to a target that is already composing.
///
/// This is the last open question of ticket B4 and the only one the sweep could
/// not answer: `.insertText` goes out on virtual key zero with a unicode
/// payload and never consults the layout, so it walks straight past whatever
/// input method is installed. With marked text in the target, the insertion can
/// commit the marked text, replace it, or be dropped, and none of the three is
/// visible from outside. Until this row ran the documentation said **unknown**,
/// which was honest and useless.
///
/// What the row can and cannot claim is worth being exact about. The
/// composition here is armed by the target itself: the fixture calls
/// `setMarkedText`, which is precisely what an input method calls on its
/// client, and after it the text view holds marked text the same way it would
/// mid word. What is missing is the other half of the protocol, an input source
/// that owns the session and would see the event first. So this measures **what
/// the client does with an insertion while it holds a composition**, on this
/// build, and it does not speak for any particular input method. A row that
/// needed Japanese installed would measure nothing on anybody else's machine.
///
/// It is AppKit only. The browser half cannot be armed at all: a page can be
/// told when a composition starts but cannot start one, and a marked range
/// inside a renderer belongs to an input method the suite has no way to invoke.
@MainActor
struct TextCompositionLiveTests {

    /// F13: no layout produces it by hand, no menu claims it, and no other row
    /// uses it, so arming the composition cannot be mistaken for anything else
    /// the target does with a key.
    static let trigger = Shortcut.physical(PhysicalKey(name: "F13", virtualKey: 105))

    /// Distinctive enough to find in the field afterwards, and ASCII so a code
    /// unit and a character are the same thing while reading the outcome.
    static let insertion = "AGENTSEAT"

    /// The same Command, to the same window, before anything is composing.
    ///
    /// Without it a dropped insertion has two explanations and the row cannot
    /// choose between them: the composition swallowed it, or nothing was
    /// delivered at all that day. The control is the one assertion here, and it
    /// is about the instrument rather than about the answer.
    static let control = "CONTROLTEXT"

    @Test("an insertion that meets a composition already in progress",
          .timeLimit(.minutes(2)),
          .enabled(if: liveSkipReason(needsFixture: true) == nil,
                   Comment(rawValue: liveSkipReason(needsFixture: true) ?? "")))
    func theInsertionMeetsAComposition() async throws {
        try await LiveStage.run(needsFixture: true, needsChrome: false) { stage in
            try await Self.measure(on: stage)
        }
    }

    /// The target's field, re-read from the target.
    ///
    /// `latest` is a snapshot and only `refresh` moves it, so a poll written
    /// against `latest` alone spins on the same stale report until it times out
    /// and then reports an insertion that did arrive as one that did not. It
    /// cost this row a whole wrong answer about input methods before the
    /// control caught it.
    private static func field(of fixture: FixtureTarget) -> String {
        fixture.refresh()
        return fixture.latest.textValue
    }

    private static func measure(on stage: LiveStage) async throws {
        let fixture = try #require(stage.fixture, "this row needs the instrumented target")
        let window  = try await adopt(fixture, onto: stage.seat, bounds: stage.virtualBounds)
        let turn    = try await stage.seat.acquire()

        guard let composed = fixture.latest.compositionText, !composed.isEmpty else {
            Issue.record(Comment(rawValue: "the instrumented target publishes no composition "
                + "channel, so this row is about an instrument that cannot be armed"))
            try stage.seat.release(turn)
            await stage.giveBack(window, of: fixture, home: stage.fixtureHome)
            return
        }

        // MARK: the control, before anything is composing

        let controlReceipt = try await stage.seat.send(
            .insertText(Self.control),
            observation: try await liveObservation(stage.seat),
            turn       : turn
        )
        let controlArrived = LivePump.run(
            until  : { Self.field(of: fixture).contains(Self.control) },
            timeout: 10
        )
        try stage.seat.confirm(controlReceipt, controlArrived ? .observed : .absent)
        #expect(
            controlArrived,
            Comment(rawValue: "an insertion into this target did not arrive even with nothing "
                + "composing, so this run can say nothing about what a composition does to one")
        )
        guard controlArrived else {
            try stage.seat.release(turn)
            await stage.giveBack(window, of: fixture, home: stage.fixtureHome)
            return
        }

        // MARK: arm the composition

        let armed  = try await stage.seat.send(
            Self.trigger,
            observation: try await liveObservation(stage.seat),
            turn       : turn
        )
        let marked = LivePump.run(
            until  : { (fixture.state()["marked"] ?? 0) > 0 },
            timeout: 5
        )
        try stage.seat.confirm(armed, marked ? .observed : .absent)

        let markedLength = fixture.state()["marked"] ?? 0
        let before       = Self.field(of: fixture)
        print("composition armed: \(Int(markedLength)) marked units, "
            + "field holds \(before.count) characters")

        guard marked else {
            // Named as what it is: the instrument never reached the state the
            // question is about, so there is no answer to report. A row that
            // went on from here would measure an ordinary insertion and print
            // it under the heading of a composition.
            Issue.record(Comment(rawValue: "the target never entered a composition after F13, "
                + "so nothing about insertion during composition is concluded"))
            try stage.seat.release(turn)
            await stage.giveBack(window, of: fixture, home: stage.fixtureHome)
            return
        }

        // MARK: the insertion, straight past the input method

        let receipt = try await stage.seat.send(
            .insertText(Self.insertion),
            observation: try await liveObservation(stage.seat),
            turn       : turn
        )
        _ = LivePump.run(
            until  : { fixture.state()["marked"] != markedLength
                || Self.field(of: fixture).contains(Self.insertion) },
            timeout: 10
        )
        LivePump.run(for: 0.5)

        let after       = Self.field(of: fixture)
        let stillMarked = fixture.state()["marked"] ?? 0
        let arrived     = after.contains(Self.insertion)
        let survived    = after.contains(composed)

        try stage.seat.confirm(receipt, arrived ? .observed : .absent)

        // The one thing the kit promises about this Command, which holds
        // whatever the target did with the composition: one event carrying the
        // whole string, counted in UTF-16 units.
        #expect(receipt.textMeasure == TextMeasure(Self.insertion.utf16.count, .utf16CodeUnits))
        #expect(receipt.eventCount == 2, "an insertion is two events, composing or not")

        let outcome = switch (arrived, survived, stillMarked > 0) {
            case (true,  true,  true) : "the insertion landed and the composition is still open"
            case (true,  true,  false): "the composition was committed and the insertion followed it"
            case (true,  false, _)    : "the insertion replaced the composition"
            case (false, true,  _)    : "the insertion was dropped and the composition stands"
            case (false, false, _)    : "the insertion and the composition are both gone"
        }
        print("""

            === insertion during composition, \(fixture.name) ===
            | control arrived | marked before | marked after | insertion arrived | composition kept |
            | \(controlArrived) | \(Int(markedLength)) | \(Int(stillMarked)) | \(arrived) | \(survived) |
            \(outcome)
            field afterwards: \(after.prefix(120))
            """)

        // No expectation on the outcome, on purpose. All five readings are a
        // real answer about this build, and asserting the one we would prefer
        // would turn a measurement into a wish. The line above is what the
        // ledger records and what the Command's documentation stops calling
        // unknown.

        try stage.seat.release(turn)
        await stage.giveBack(window, of: fixture, home: stage.fixtureHome)
    }
}

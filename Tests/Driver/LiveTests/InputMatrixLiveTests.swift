//
//  InputMatrixLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import CursorGuard
import Foundation
import PrivateSymbols
import SeatCore
import SeatInput
import SeatSession
import TargetReader
import Testing
import VirtualScreens
import WindowPlacement

/// Outcome is one cell of the matrix: what was asked, whether the target did
/// it, and whether the person's seat noticed.
nonisolated struct Outcome {

    let target : String
    let action : String
    var effect : String = "not run"
    var effectPassed = false
    var seat   : String = "not read"
    var seatIntact   = false
    var receipt: String = ""
    var error  : String = ""

    /// How many HID events the tap saw from the person while the action ran.
    ///
    /// It is the difference between a failure and an inconclusive row. The tap
    /// sees the person's hand and never the kit's events, which are posted to
    /// one process and never into the HID stream, so a non zero count is proof
    /// that somebody touched the mouse or the keyboard during the measurement.
    /// A hand on the machine can move the target's focus, scroll the page under
    /// the click and drag the cursor, and none of that is evidence about the
    /// driver: two runs out of eight have failed this way, every time with
    /// hundreds of physical events in the log. So the row is declared
    /// `inconclusive`, and an inconclusive row is never a pass either.
    var physicalEvents: UInt64 = 0

    /// Whether this row could not give its Turn back.
    ///
    /// It stops the run. A Turn that was not released is held forever, and
    /// `acquire` has no timeout, so the next row does not fail: it waits, and
    /// the whole suite hangs with no output at all. One row that cannot finish
    /// is a finding; a suite that hangs is nothing.
    var turnStuck = false

    /// Whether the target saw the key event of a shortcut row arrive, which is
    /// a different claim from whether it acted on it. Nil for a row that is not
    /// a shortcut. It is the whole point of the shortcut half of the matrix:
    /// Command and V is delivered to both families and acted on by neither.
    var shortcutDelivered: Bool?

    /// Whether the target published the counter this row reads. A target that
    /// cannot be read says nothing about the driver, so the row is neither a
    /// pass nor a failure — the same rule a hand on the machine gets.
    var countersUnreadable = false

    var isInconclusive: Bool {
        countersUnreadable || (physicalEvents > 0 && !(effectPassed && seatIntact))
    }

    var verdict: String {
        if isInconclusive { return "INCO" }
        return effectPassed ? "PASS" : "FAIL"
    }

    var line: String {
        String(
            format: "| %-14@ | %-8@ | %-4@ | %-42@ | %-4@ | %@",
            target, action,
            verdict, effect,
            seatIntact ? "OK" : (isInconclusive ? "HAND" : "VIOL"), seat
        )
    }
}

/// CalibratedPlatform is a platform with someone else's settle, and it exists
/// for one job: running the same matrix at 20, 40 and 80 ms to find out what
/// the wait actually has to be (`AGENTSEAT_SETTLE_MS`). It is test code because
/// the answer belongs in `InputPlatform.preparationSettle(for:)`, not in an option.
nonisolated struct CalibratedPlatform: InputPlatform {

    let base  : any InputPlatform
    let settle: Duration?

    /// The modifier policy to use instead of the family's own, for the run that
    /// measures the other half of the spike. Nil keeps the family's answer.
    let policy: ModifierPolicy?

    init(base: any InputPlatform, settle: Duration? = nil, policy: ModifierPolicy? = nil) {
        self.base   = base
        self.settle = settle
        self.policy = policy
    }

    func preparation(for command: InputCommand) -> Preparation { base.preparation(for: command) }

    func preparationSettle(for command: InputCommand) -> Duration {
        settle ?? base.preparationSettle(for: command)
    }

    func modifierPolicy(for command: InputCommand) -> ModifierPolicy {
        policy ?? base.modifierPolicy(for: command)
    }

    var dragPacing     : DragPacing      { base.dragPacing }
    var keyRepeatPacing: KeyRepeatPacing { base.keyRepeatPacing }
}

/// The acceptance test of the whole input path: the matrix, run against the
/// real thing.
///
/// Two target families, each **adopted on the Virtual Display**, each driven
/// with click, keyboard, scroll and drag, and after every single action both
/// halves of the promise are checked: the target did what was asked, and the
/// User Seat did not move. The person's frontmost application stays in front,
/// the target never comes forward, and the physical cursor does not travel a
/// point.
///
/// The AppKit target is the package's own Fixture, launched as a process and
/// read through the file it publishes. Nothing resizes it and nothing works
/// around its layout: it publishes whether each control it exposes hit tests to
/// itself, and a row whose control is unreachable fails as a defect of the
/// Fixture instead of being attributed to the driver.
///
/// Stage Manager stashes every inactive window on a display down to a
/// thumbnail, so the targets go onto the Virtual Display **one at a time**, and
/// each one is staged and confirmed at full size by the window server before
/// anything is posted to it.
@Suite("The Fixture and the input matrix on the running host", .serialized)
@MainActor
struct InputMatrixLiveTests {

    /// Why the menu resolved rows are known issues rather than failures.
    static let knownIssueReason = "A key equivalent is resolved by the frontmost application menu, and the seat may never be frontmost; see docs/SpiLedger.md under Discarded. The row stays measured, so the build where it turns green is an unexpected pass rather than nobody noticing."

    /// The family a finished row belonged to, recovered from its printed name
    /// because an `Outcome` keeps no reference to its target.
    private func familyOfTarget(named name: String) -> TargetFamily {
        name.contains("Chrome") ? .chromium : .appKit
    }

    /// How long an effect may take to show up in the target's own report.
    static let effectTimeout: Double = 2

    /// The fixture is the consumer's and may simply not be on this machine, so
    /// the gate asks only for the browser. A run without it measures the
    /// Chromium family alone and **says so**: half the matrix labelled as half
    /// is evidence, half the matrix reported as a pass is not.
    @Test("the input matrix reaches every target family present, with the seat intact",
          .timeLimit(.minutes(3)),
          .enabled(if: liveSkipReason(needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(needsChrome: true) ?? "")))
    func theInputMatrix() async throws {

        var outcomes: [Outcome] = []
        var fenceSnapshot: FenceSnapshot?

        try await LiveStage.run(needsFixture: FixtureTarget.isAvailable) { stage in

            if stage.fixture == nil {
                Issue.record(Comment(rawValue: FixtureTarget.unavailableReason
                    + " The AppKit half of this matrix did not run: every row below is"
                    + " the Chromium family alone."))
            }

            // MARK: one target at a time, alone on the display

            for target in stage.targets {
                let adopted = try await adopt(
                    target,
                    onto  : stage.seat,
                    bounds: stage.virtualBounds
                )
                target.refresh()
                if let fixture = stage.fixture,
                   target.window.windowNumber == fixture.window.windowNumber {
                    #expect(
                        fixture.latest.controlsAreHitTestable,
                        Comment(rawValue: "the instrumented target's controls stopped being"
                            + " reachable once staged: " + fixture.latest.controlHitTestReport)
                    )
                }

                for action in Action.all {
                    // Printed before the row, and flushed, because the only
                    // thing worse than a row that hangs is a log that does not
                    // say which one.
                    print("  -> \(target.name) \(action.name)")
                    fflush(stdout)
                    let outcome = await perform(
                        action,
                        on    : target,
                        seat  : stage.seat,
                        window: adopted,
                        fence : stage.fence
                    )
                    outcomes.append(outcome)
                    print("  <- \(target.name) \(action.name): \(outcome.verdict)")
                    fflush(stdout)
                    if outcome.turnStuck { break }
                }

                await stage.giveBack(adopted, of: target, home: stage.home(of: target))
            }

            // The drag still has to reach the fixture's process, control or no
            // control: that is the part the driver is answerable for. Asserted here
            // and not after the stage comes down, because after it the fixture is
            // already terminated.
            if let fixture = stage.fixture {
                fixture.refresh()
                #expect(
                    fixture.latest.syntheticMouseDragCount > 0,
                    "no dragged event ever reached the fixture: \(fixture.diagnostics)"
                )
                #expect(fixture.latest.lastMouseWindowNumber == fixture.window.windowNumber)
            }

            fenceSnapshot = stage.fence.snapshot()
        }
        let snapshot = try #require(fenceSnapshot)
        verify(
            outcomes,
            snapshot: snapshot
        )
    }

    @Test(
        "the Chromium input matrix runs independently of the AppKit fixture",
        .timeLimit(.minutes(3)),
        .enabled(
            if: liveSkipReason(needsChrome: true) == nil,
            Comment(rawValue: liveSkipReason(needsChrome: true) ?? "")
        )
    )
    func chromiumInputMatrix() async throws {
        var outcomes: [Outcome] = []
        var snapshot: FenceSnapshot?
        try await LiveStage.run(
            needsFixture: false,
            needsChrome : true,
            configuration: SeatHostConfiguration(
                restoresUserFocus            : true,
                allowUnvalidatedFocusRecovery: true
            )
        ) { stage in
            let target = try #require(stage.chrome)
            let window = try await adopt(
                target,
                onto  : stage.seat,
                bounds: stage.virtualBounds
            )
            target.refresh()
            let reading = try WindowReader.windowSnapshot(
                processID   : target.processID,
                windowNumber: target.windowNumber
            )
            let hasWebArea = reading.axTree.contains { $0.role == "AXWebArea" }
            print("CHROMIUM_MATRIX readiness nodes=\(reading.axTree.count) web-area=\(hasWebArea)")
            try handBackLiveFocus(
                to      : stage.personBefore,
                avoiding: target.processID
            )
            for action in Action.all {
                print("CHROMIUM_MATRIX -> \(action.name)")
                let outcome = await perform(
                    action,
                    on    : target,
                    seat  : stage.seat,
                    window: window,
                    fence : stage.fence
                )
                outcomes.append(outcome)
                if outcome.turnStuck { break }
            }
            await stage.giveBack(
                window,
                of  : target,
                home: stage.chromeHome
            )
            snapshot = stage.fence.snapshot()
        }
        #expect(outcomes.count == Action.all.count)
        verify(
            outcomes,
            snapshot: try #require(snapshot)
        )
    }

    private func verify(
        _ outcomes: [Outcome],
        snapshot  : FenceSnapshot
    ) {
        print("\n| target         | action   | fx   | effect                                     | seat | detail")
        for outcome in outcomes {
            print(outcome.line)
            if !outcome.receipt.isEmpty { print("      receipt: \(outcome.receipt)") }
            if !outcome.error.isEmpty   { print("      error:   \(outcome.error)") }
        }
        print("""
            fence: \(snapshot.observedEventCount) HID events observed, \
            \(snapshot.clampedEventCount) clamped, \
            \(snapshot.disableCount) disables
            """)


        // MARK: what the matrix has to prove

        for outcome in outcomes {

            // A hand on the machine during the action makes the row
            // inconclusive, and an inconclusive row is never a pass: it is
            // reported and skipped, because nothing about the driver can be
            // concluded from a measurement the person was moving inside of.
            if outcome.isInconclusive {
                let detail = "\(outcome.target) \(outcome.action): inconclusive, "
                    + "\(outcome.physicalEvents) physical events during the action. "
                    + "Rerun without touching the machine."
                Issue.record(Comment(rawValue: detail))
                continue
            }

            #expect(outcome.seatIntact, "\(outcome.target) \(outcome.action): \(outcome.seat)")

            if let row = ShortcutRow(rawValue: outcome.action) {
                // Delivery is asserted for every shortcut row, the ones nothing
                // is expected to act on included: an event that does not even
                // arrive is a different finding from one that arrives and is
                // ignored, and only the second is the measured behaviour.
                #expect(
                    outcome.shortcutDelivered == true,
                    "\(outcome.target) \(outcome.action): the key event never reached the target"
                )
                let expectation = row.expectation(on: familyOfTarget(named: outcome.target))
                if expectation == .effectNotObservable {
                    // Delivery was already asserted above, and delivery is all
                    // this family lets anybody see. Reporting it as a pass or a
                    // failure would both be lies.
                    Issue.record(Comment(rawValue: "\(outcome.target) \(outcome.action): "
                        + "delivered, and this family exposes no effect to observe"))
                    continue
                }
                if expectation == .deliveredOnly {
                    withKnownIssue(
                        Comment(rawValue: "\(outcome.action) reaches the target and the "
                            + "target does not act on it. " + Self.knownIssueReason)
                    ) {
                        #expect(outcome.effectPassed, Comment(rawValue: outcome.effect))
                    }
                    continue
                }
            }

            #expect(
                outcome.effectPassed,
                "\(outcome.target) \(outcome.action): \(outcome.effect) \(outcome.error)"
            )
        }

        #expect(snapshot.disableCount == 0, "the cursor fence was disabled during the run")
    }

    // MARK: The Fixture's layout

    /// The target's own layout defect, closed with an assertion instead of an
    /// eye.
    ///
    /// The old fixture put its controls inside a scrollable document taller
    /// than the window: at the default height the slider sat 95 points **below**
    /// the bottom edge, and at 901, the tallest height reachable through
    /// `AXSize` on the Virtual Display, a text view covered the point the
    /// slider published, so a drag landed on the right coordinates and the
    /// wrong view. Both turned a matrix row into an inconclusive one.
    ///
    /// This drives the window to every size that matters and asks the Fixture,
    /// at each of them, whether every control it exposes hit tests to itself
    /// through the content view. `AXSize` is the harness's, never the kit's:
    /// the kit's whole use of accessibility is `AXPosition`, `AXRaise` and
    /// `_AXUIElementGetWindow`.
    @Test("every driven control is inside the window and hit testable at every reachable size",
          .enabled(if: liveSkipReason(needsFixture: true) == nil,
                   Comment(rawValue: liveSkipReason(needsFixture: true) ?? "")))
    func theFixtureLayoutHoldsAtEverySize() async throws {

        LivePump.prepare()
        #expect(Permissions.preflight(.accessibility), "Accessibility is not granted to the runner")

        let fixture = try FixtureTarget.launched()
        defer { fixture.terminate() }

        let width = fixture.latest.windowWidth
        let sizes: [(label: String, size: CGSize?)] = [
            ("default", nil),
            ("901 pt, the tallest the Virtual Display allows",
             CGSize(width: width, height: 901)),
            ("the window's own minimum",
             CGSize(width: 200, height: 200)),
        ]

        for (label, size) in sizes {
            if let size {
                let result = fixture.resizeThroughAccessibility(to: size)
                #expect(result == .success, "AXSize refused \(size): \(result.rawValue)")
                LivePump.run(for: 0.8)
            }
            fixture.refresh()
            let report = fixture.latest
            print(String(
                format: "  %-48@ window %.0f x %.0f, slider y %.0f, scroll y %.0f, %@",
                label, report.windowWidth, report.windowHeight,
                report.sliderStartWindowY, report.scrollWindowY,
                report.controlHitTestReport
            ))
            #expect(
                report.controlsAreHitTestable,
                "\(label): \(report.controlHitTestReport)"
            )
            // The defect this replaces was exactly a negative window y: a
            // control the window reports below its own bottom edge.
            #expect(report.sliderStartWindowY > 0, "\(label): the slider is off the window")
            #expect(report.scrollWindowY > 0, "\(label): the scroll area is off the window")
            #expect(report.metalHeight > 0, "\(label): the Metal region has no height")
        }
    }

    // MARK: One action

    /// The six rows of the matrix, in the order they are run. Keyboard first
    /// on purpose: a click can move a target's own focus, and the point of the
    /// keyboard row is that a key reaches the window that already has it.
    ///
    /// `insertText` runs second, while the first responder is still the target's
    /// text field, and it is the row where the two families differ in what they
    /// need: a Chromium renderer refuses a key event carrying more than one
    /// character without the Preparation, and a native one takes it either way.
    ///
    /// Command and V used to be a row here, as the detector for the key
    /// equivalent a menu resolves. It moved to `ShortcutRow`, which drives all
    /// eight of them under one expectation table: two rows for one measurement
    /// are two places to update the same evidence, and one of them would rot.
    enum Action: Hashable {
        case keyboard, insertText, click, scroll, drag
        case shortcut(ShortcutRow)

        /// The mechanical rows first, then the eight shortcuts. The order is
        /// the old one with the shortcuts appended, because the mouse rows move
        /// the first responder off the text field and every shortcut row needs
        /// it there.
        static let all: [Action] =
            [.keyboard, .insertText] + ShortcutRow.allCases.map(Action.shortcut)
            + [.click, .scroll, .drag]

        var name: String {
            switch self {
            case .keyboard:        "keyboard"
            case .insertText:      "insertText"
            case .click:           "click"
            case .scroll:          "scroll"
            case .drag:            "drag"
            case .shortcut(let r): r.rawValue
            }
        }

        var effectKey: String {
            switch self {
            case .keyboard:   "keys"
            case .insertText: "field"
            case .click:      "clicks"
            case .scroll:     "wheel"
            case .drag:       "drag"
            // The counter of effects, not the code: a row watches for it to
            // move and then checks that the code it moved to is its own.
            case .shortcut:   "shortcutEffects"
            }
        }

        var shortcutRow: ShortcutRow? {
            if case .shortcut(let row) = self { row } else { nil }
        }
    }

    /// The string the bulk insertion row puts into the target's field. Long
    /// enough that no target could produce it from one keystroke, short enough
    /// that a window title still carries the count of it.
    static let insertedSample = String(repeating: "agentseat", count: 8)

    /// One action, through the whole hold: acquire, send, verify, confirm,
    /// release.
    ///
    /// This tests the seat as much as the driver. The Command is the same one a
    /// driver would post alone, but the path to it is the seat's: the hold
    /// is exclusive, the marker is the hold's, the identity and the User Seat are
    /// re-read immediately before the events, and the hold cannot be given back
    /// until the effect has been answered for. The consumer is the one that
    /// verifies, which is the contract: the target's own counters say whether
    /// anything happened, and `confirm` tells the seat.
    private func perform(
        _ action: Action,
        on target: any MatrixTarget,
        seat     : AgentSeat,
        window   : AdoptedWindow,
        fence    : CursorFence
    ) async -> Outcome {

        var outcome    = Outcome(target: target.name, action: action.name)
        var before     = target.state()
        let baseline   = UserSeatState.capture()
        let handBefore = fence.snapshot().observedEventCount
        let settle     = settleOverrideMilliseconds().map { Duration.milliseconds($0) }
        let policy     = modifierPolicyOverride()
        let platform   : any InputPlatform = (settle == nil && policy == nil)
            ? target.platform
            : CalibratedPlatform(base: target.platform, settle: settle, policy: policy)

        var turn: Turn?

        func mark(_ step: String) {
            print("       . \(action.name) \(step)")
            fflush(stdout)
        }

        do {
            mark("acquire")
            let held = try await seat.acquire()
            turn = held
            mark("acquired \(held.generation)")

            if action.shortcutRow == .cancel, target.family == .chromium {
                let setup = try await seat.send(
                    Shortcut.physical(PhysicalKey(name: "F8", virtualKey: 100)),
                    observation: try await liveObservation(seat),
                    turn       : held,
                    platform   : platform
                )
                let opened = LivePump.run(until: { target.state()["dialogOpen"] == 1 }, timeout: 2)
                try seat.confirm(setup, opened ? .observed : .absent)
                try #require(opened, "The browser must open the dialog before cancellation is measured")
                before = target.state()
            }
            let observesWindows = action.shortcutRow?.oracleIsANewWindow == true
            let windowsBefore = observesWindows ? Self.visibleWindowIDs(of: target.window.processID) : nil
            if observesWindows {
                try #require(windowsBefore != nil, "The target's window list is unavailable")
            }

            let receipt: InputReceipt
            mark("send")
            if let row = action.shortcutRow {
                // Sent as a Shortcut and not as a built Command, so the seat
                // resolves the character through the installed layout. On the
                // Dvorak machine this was written on, a hard coded virtual key
                // would press something else entirely.
                receipt = try await seat.send(
                    row.shortcut,
                    observation: try await liveObservation(seat),
                    turn       : held,
                    platform   : platform
                )
            } else {
                receipt = try await seat.send(
                    try makeCommand(action, for: target),
                    observation: try await liveObservation(seat),
                    turn       : held,
                    platform   : platform
                )
            }
            outcome.receipt = "\(receipt.eventCount) events, "
                + "\(receipt.route.routedEventCount) routed to window "
                + "\(receipt.route.windowNumber) on connection "
                + "\(receipt.route.ownerConnectionID), preparation "
                + "\(receipt.preparation.rawValue), settle "
                + "\(receipt.timing.settleNanoseconds / 1_000_000) ms, posting "
                + "\(receipt.timing.postingNanoseconds / 1_000) us, generation \(held.generation)"

            mark("sent")
            let cursorAfterSend = UserSeatState.capture().cursor
            mark("waiting for \(action.effectKey)")
            var change = waitForChange(action.effectKey, from: before, in: target)
            if let windowsBefore {
                guard let windowsAfter = Self.visibleWindowIDs(of: target.window.processID) else {
                    throw LiveFailure.unsupported("The target's window list became unavailable")
                }
                change = (!windowsAfter.subtracting(windowsBefore).isEmpty, Double(windowsAfter.count))
            }
            mark("observed \(change.changed)")
            outcome.effectPassed = change.changed

            if let row = action.shortcutRow {
                // Two claims, kept apart. Delivery is the target having seen
                // the key event; effect is the target having done the thing.
                // Every menu key equivalent is expected to be the first without
                // the second, and one counter would hide exactly that.
                let after = target.state()
                outcome.shortcutDelivered = after["shortcutDelivered"] == row.number
                outcome.effectPassed = observesWindows ? change.changed
                    : change.changed && after["shortcutEffect"] == row.number
                if row == .cancel, target.family == .chromium {
                    outcome.effectPassed = outcome.effectPassed && after["dialogOpen"] == 0
                }
            }
            // The target publishes its counters in a window title, and a title
            // read while the page rewrites it comes back without them. Printing
            // the absence as a number is what made one row fail for having
            // measured nothing and its neighbour pass for the same reason.
            if let windowsBefore {
                outcome.effect = "visible windows \(windowsBefore.count) -> \(Int(change.value))"
            } else if before[action.effectKey] == nil || target.state()[action.effectKey] == nil {
                outcome.countersUnreadable = true
                outcome.effect = "\(action.effectKey) unreadable: the target published no counters"
            } else {
                outcome.effect = "\(action.effectKey) \(before[action.effectKey] ?? -1) -> \(change.value)"
            }
            outcome.receipt     += "; cursor \(baseline.cursor) -> \(cursorAfterSend) -> "
                + "\(UserSeatState.capture().cursor)"

            // The consumer verified, so the consumer answers. `observed` when
            // the counter moved, `absent` when it verifiably did not: the one
            // answer never given here is `unknown`, because that would be the
            // seat's end.
            mark("confirm")
            try seat.confirm(receipt, change.changed ? .observed : .absent)
            mark("confirmed")

        } catch {
            outcome.error  = "\(error)"
            outcome.effect = "not sent"
        }

        LivePump.run(for: 0.3)
        let seatState = seatCheck(
            baseline      : baseline,
            target        : target,
            physicalEvents: fence.snapshot().observedEventCount &- handBefore
        )
        outcome.seatIntact     = seatState.intact
        outcome.seat           = seatState.detail
        outcome.physicalEvents = fence.snapshot().observedEventCount &- handBefore

        mark("seat check")
        if let turn {
            mark("conclude observation")
            _ = await seat.concludeObservation()
            mark("release")
            do {
                try seat.release(turn)
            } catch {
                outcome.error    += " | release refused: \(error)"
                outcome.turnStuck = true
                Issue.record(Comment(rawValue: "\(target.name) \(action.name): the Turn was "
                    + "refused and is still held (\(error)). Every later row would wait on it "
                    + "forever, so the run stops here."))
            }
        }
        return outcome
    }

    /// Reads the target's on-screen Window IDs without inferring native panels
    /// from page counters. A failed reading is unknown, never an empty set.
    private static func visibleWindowIDs(of processID: Int32) -> Set<Int>? {
        guard let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var result: Set<Int> = []
        for entry in entries {
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            guard owner.int32Value == processID else { continue }
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { return nil }
            result.insert(number.intValue)
        }
        return result
    }

    private func makeCommand(_ action: Action, for target: any MatrixTarget) throws -> InputCommand {
        switch action {
        case .shortcut:
            // Unreachable: `perform` sends a shortcut through the seat's own
            // Shortcut entry point, which is where the layout is consulted.
            throw LiveFailure.unsupported("a shortcut row does not build a Command here")

        case .keyboard:
            return .key(virtualKey: 6, text: "Z", modifiers: [])

        case .click:
            let point = try #require(target.clickPoint(), "the target has no clickable point")
            return .click(try target.location(of: point))

        case .scroll:
            let point = try #require(target.scrollPoint(), "the target has nothing to scroll")
            return .scroll(try target.location(of: point), deltaY: -6)

        case .drag:
            let path = try #require(target.dragEndpoints(), "the target has nothing to drag")
            // Both ends from **one** reading: `drag(from:to:)` keeps the
            // observation on its interpolated points only when the two agree,
            // and two readings never do.
            let ends = try target.locations(of: [path.start, path.end])
            return .drag(from: ends[0], to: ends[1])

        case .insertText:
            return .insertText(Self.insertedSample)

        }
    }

    /// Polls the target's own report until the counter moves, pumping rather
    /// than sleeping so this process stays a real application while it waits.
    private func waitForChange(
        _ key    : String,
        from before: [String: Double],
        in target: any MatrixTarget
    ) -> (changed: Bool, value: Double) {

        let deadline = Date().addingTimeInterval(Self.effectTimeout)
        var latest   = before[key] ?? 0
        while Date() < deadline {
            LivePump.run(for: 0.1)
            // A sample the target could not publish is skipped, not compared:
            // treating "unreadable" as a value makes an unread counter look
            // like a counter that moved.
            guard let sample = target.state()[key] else { continue }
            latest = sample
            if latest != before[key] { return (true, latest) }
        }
        return (false, latest)
    }

    /// The User Seat, checked after every single action.
    ///
    /// The window order is only asserted where it means something: on the
    /// person's own displays. A target on the Virtual Display is in front *of
    /// that display*, which is the whole point of the seat, so the ordering
    /// question is skipped there and the frontmost application answers it
    /// instead.
    private func seatCheck(
        baseline      : UserSeatState,
        target        : any MatrixTarget,
        physicalEvents: UInt64
    ) -> (intact: Bool, detail: String) {

        let now      = UserSeatState.capture()
        var problems: [String] = []
        var notes   : [String] = []

        if now.frontmostProcessID != baseline.frontmostProcessID {
            problems.append("frontmost changed to \(now.frontmostName)")
        }
        if now.frontmostProcessID == target.window.processID {
            problems.append("the target became the front application")
        }
        if abs(now.cursor.x - baseline.cursor.x) > 0.5
            || abs(now.cursor.y - baseline.cursor.y) > 0.5 {
            // Who moved it is the whole question, and the fence is what answers
            // it: the tap sees the person's hand and never the driver's events,
            // which are posted to one process and never to the HID stream. A
            // cursor that moved while the tap counted physical events moved
            // because someone touched the mouse, and the kit reports that
            // instead of claiming it.
            let moved = String(
                format: "the cursor moved by %.1f, %.1f",
                now.cursor.x - baseline.cursor.x, now.cursor.y - baseline.cursor.y
            )
            if physicalEvents > 0 {
                notes.append("\(moved), with \(physicalEvents) physical events: the person's hand")
            } else {
                problems.append("\(moved), with no physical event to explain it")
            }
        }
        // The Preparation grants the target its own active and key state, on
        // purpose and inside its own process only. It is reported, never
        // counted as a violation.
        if target.isInternallyActive { notes.append("target internally active") }

        let summary = problems.isEmpty
            ? "front \(now.frontmostName), cursor still"
            : problems.joined(separator: "; ")
        return (
            problems.isEmpty,
            notes.isEmpty ? summary : summary + " [\(notes.joined(separator: ", "))]"
        )
    }

    // MARK: Adoption, with the kit's own relocator



}

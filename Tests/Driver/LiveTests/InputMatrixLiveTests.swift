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
    let settle: Duration

    func preparation(for command: InputCommand) -> Preparation { base.preparation(for: command) }
    func preparationSettle(for command: InputCommand) -> Duration { settle }
    var dragPacing: DragPacing { base.dragPacing }
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

    /// How long an effect may take to show up in the target's own report.
    static let effectTimeout: Double = 2

    @Test("click, keyboard, scroll and drag reach both families with the seat intact",
          .enabled(if: liveSkipReason(needsFixture: true, needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(needsFixture: true, needsChrome: true) ?? "")))
    func theInputMatrix() async throws {

        LivePump.prepare()
        #expect(Permissions.preflight(.postEvent),     "Post Event is not granted to the test runner")
        #expect(Permissions.preflight(.accessibility), "Accessibility is not granted to the test runner")

        let baselineOnline = Set(try DisplayList.online())
        let baselineMain   = CGMainDisplayID()
        let personBefore   = UserSeatState.capture()
        var outcomes: [Outcome] = []

        if let settle = settleOverrideMilliseconds() {
            print("settle calibration run: \(settle) ms")
        }

        // MARK: the two targets, both left exactly where they were found

        let fixture = try FixtureTarget.launched()
        defer { fixture.terminate() }
        let firstReport = fixture.latest
        #expect(
            firstReport.controlsAreHitTestable,
            """
            the instrumented target opened with an unreachable control at \
            \(Int(firstReport.windowWidth)) by \(Int(firstReport.windowHeight)): \
            \(firstReport.controlHitTestReport)
            """
        )

        // A fixture that came up in front of the person's own application hands
        // the focus straight back: the matrix is about a target that is *not*
        // the front application.
        if firstReport.applicationIsActive,
           let previous = NSRunningApplication(processIdentifier: personBefore.frontmostProcessID),
           previous.processIdentifier != firstReport.processID {
            previous.activate()
            LivePump.run(for: 0.5)
        }

        let chromeWasRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
        let chrome = try openProbePage(handingFocusBackTo: personBefore)
        defer {
            if !chromeWasRunning { quitChrome() }
        }

        let fixtureHome = WindowServerProbe.geometry(of: fixture.window.windowNumber)?.frame
        let chromeHome  = chrome.map(\.originalFrame)

        // MARK: the seat, whole, from the kit

        let host = SeatHost(configuration: SeatHostConfiguration())
        var hostIsUp = false
        defer {
            if hostIsUp { Task { await host.stop() } }
        }
        try await host.start()
        hostIsUp = true
        #expect(host.state == .ready, "the host came up \(host.state.rawValue)")

        let seat   = try host.makeSeat()
        let events = SeatEventLog()
        let seatEventTask = Task { @MainActor in
            for await event in seat.events { events.record(event) }
        }
        let hostEventTask = Task { @MainActor in
            for await event in host.events { events.record(event) }
        }
        defer {
            seatEventTask.cancel()
            hostEventTask.cancel()
        }

        let displayID     = try #require(host.displayID)
        let virtualBounds = CGDisplayBounds(displayID)
        let fence         = try #require(host.fence, "the host started without a fence")
        print("virtual display \(displayID) at \(virtualBounds), fence \(fence.isActive)")

        // MARK: the AppKit half

        let adoptedFixture = try await adopt(fixture, onto: seat, bounds: virtualBounds)
        fixture.refresh()
        #expect(
            fixture.latest.controlsAreHitTestable,
            Comment(rawValue: "the instrumented target's controls stopped being"
                + " reachable once staged: " + fixture.latest.controlHitTestReport)
        )

        for action in Action.all {
            outcomes.append(await perform(
                action,
                on    : fixture,
                seat  : seat,
                window: adoptedFixture,
                fence : fence
            ))
        }

        _ = await seat.release(adoptedFixture, .returnToUserSeat)
        if let fixtureHome, WindowServerProbe.geometry(of: fixture.window.windowNumber)
            .map({ !rectanglesMatchLoosely($0.frame, fixtureHome) }) == true {
            restore(fixture.window, to: fixtureHome.origin)
        }
        LivePump.run(for: 1.0)

        // MARK: the Chromium half, alone on the display

        if let chrome {
            let adoptedChrome = try await adopt(chrome, onto: seat, bounds: virtualBounds)
            for action in Action.all {
                outcomes.append(await perform(
                    action,
                    on    : chrome,
                    seat  : seat,
                    window: adoptedChrome,
                    fence : fence
                ))
            }
            _ = await seat.release(adoptedChrome, .returnToUserSeat)
            if let chromeHome, WindowServerProbe.geometry(of: chrome.window.windowNumber)
                .map({ !rectanglesMatchLoosely($0.frame, chromeHome) }) == true {
                restore(chrome.window, to: chromeHome.origin)
            }
            LivePump.run(for: 1.0)
        }

        // MARK: the report and the teardown

        let fenceSnapshot = fence.snapshot()
        print("\n| target         | action   | fx   | effect                                     | seat | detail")
        for outcome in outcomes {
            print(outcome.line)
            if !outcome.receipt.isEmpty { print("      receipt: \(outcome.receipt)") }
            if !outcome.error.isEmpty   { print("      error:   \(outcome.error)") }
        }
        print("""
            fence: \(fenceSnapshot.observedEventCount) HID events observed, \
            \(fenceSnapshot.clampedEventCount) clamped, \
            \(fenceSnapshot.disableCount) disables
            """)

        for _ in 0..<40 { await Task.yield() }
        let teardown = await host.stop()
        hostIsUp = false
        LivePump.run(for: 0.4)

        print(
            "teardown: display removed \(teardown.displayRemoved), "
                + "fence released \(teardown.fenceReleased), "
                + "topology \(String(describing: teardown.topologyRestoration)), "
                + "\(events.events.count) events"
        )
        #expect(teardown.displayRemoved, "the virtual display was left online")
        #expect(teardown.fenceReleased, "the fence's tap was left installed")
        #expect(teardown.topologyRestoration != .topologyChangedByUser,
                "the display set changed during the run, the topology was left alone")
        #expect(
            events.events.contains { event in
                if case .hostStateChanged(_, let to, _) = event { return to == .ready }
                return false
            },
            "the host's transitions never reached the event stream"
        )

        #expect(Set(try DisplayList.online()) == baselineOnline, "a display was left behind")
        #expect(CGMainDisplayID() == baselineMain)

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

            // Command and V is delivered and not acted on, on both families,
            // and that is the measurement rather than a regression: a key
            // equivalent is resolved by the frontmost application's menu, and
            // the seat may never be frontmost. The row stays and stays
            // measured, so the day a build acts on it the known issue turns
            // into an unexpected pass instead of nobody noticing.
            if outcome.action == Action.paste.rawValue {
                withKnownIssue(
                    """
                    Command and V reaches both families and neither pastes: the target \
                    reports itself active, its window key and `paste:` resolving to its own \
                    text view, and nothing arrives. Eleven routes were measured and every \
                    one failed; see docs/spi-ledger.md. The person's clipboard is not \
                    touched here, so what this row detects is the resolution and not the \
                    content: a build where it turns green needs the reading redone.
                    """
                ) {
                    #expect(
                        outcome.effectPassed,
                        "\(outcome.target) \(outcome.action): \(outcome.effect) \(outcome.error)"
                    )
                }
                continue
            }

            if outcome.isInconclusive {
                print("  inconclusive, not judged: \(outcome.target) \(outcome.action) — \(outcome.effect)")
                continue
            }
            #expect(
                outcome.effectPassed,
                "\(outcome.target) \(outcome.action): \(outcome.effect) \(outcome.error)"
            )
        }

        // The drag still has to reach the fixture's process, control or no
        // control: that is the part the driver is answerable for.
        fixture.refresh()
        #expect(
            fixture.latest.syntheticMouseDragCount > 0,
            "no dragged event ever reached the fixture: \(fixture.diagnostics)"
        )
        #expect(fixture.latest.lastMouseWindowNumber == fixture.window.windowNumber)
        #expect(fenceSnapshot.disableCount == 0, "the cursor fence was disabled during the run")
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
    /// `paste` is not a Command, it is the **detector**: a plain key Command
    /// carrying Command and V, which is resolved by the frontmost application's
    /// menu and therefore by nobody here. It runs before the mouse rows for the
    /// same reason the keyboard row runs first and a sharper one: the target's
    /// Paste item is only enabled while the first responder can accept text, and
    /// clicking a button or dragging a slider moves the first responder off the
    /// text field.
    enum Action: String, CaseIterable {
        case keyboard, insertText, paste, click, scroll, drag

        static let all = Action.allCases

        var effectKey: String {
            switch self {
            case .keyboard:   "keys"
            case .insertText: "field"
            case .click:      "clicks"
            case .scroll:     "wheel"
            case .drag:       "drag"
            case .paste:      "chars"
            }
        }
    }

    /// `kVK_ANSI_V`, written out because a bare 9 in the middle of a Command is
    /// the kind of constant that gets copied into the wrong row. The character
    /// travels on the event too, so a layout where V is not at 9 still produces
    /// the V a menu item would match on.
    static let vKeyCode: CGKeyCode = 9

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

        var outcome    = Outcome(target: target.name, action: action.rawValue)
        let before     = target.state()
        let baseline   = UserSeatState.capture()
        let handBefore = fence.snapshot().observedEventCount
        let platform   = settleOverrideMilliseconds().map {
            CalibratedPlatform(base: target.platform, settle: .milliseconds($0)) as any InputPlatform
        } ?? target.platform

        var turn: Turn?

        do {
            let held = try await seat.acquire()
            turn = held

            let command = try makeCommand(action, for: target)
            let receipt = try await seat.send(
                command,
                to      : window,
                turn    : held,
                platform: platform
            )
            outcome.receipt = "\(receipt.eventCount) events, "
                + "\(receipt.route.routedEventCount) routed to window "
                + "\(receipt.route.windowNumber) on connection "
                + "\(receipt.route.ownerConnectionID), preparation "
                + "\(receipt.preparation.rawValue), settle "
                + "\(receipt.timing.settleNanoseconds / 1_000_000) ms, posting "
                + "\(receipt.timing.postingNanoseconds / 1_000) us, generation \(held.generation)"

            let cursorAfterSend = UserSeatState.capture().cursor
            let change = waitForChange(action.effectKey, from: before, in: target)
            outcome.effectPassed = change.changed
            // The target publishes its counters in a window title, and a title
            // read while the page rewrites it comes back without them. Printing
            // the absence as a number is what made one row fail for having
            // measured nothing and its neighbour pass for the same reason.
            if before[action.effectKey] == nil || target.state()[action.effectKey] == nil {
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
            try seat.confirm(receipt, change.changed ? .observed : .absent)

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

        if let turn {
            _ = await seat.concludeObservation()
            do { try seat.release(turn) }
            catch { outcome.error += " | release refused: \(error)" }
        }
        return outcome
    }

    private func makeCommand(_ action: Action, for target: any MatrixTarget) throws -> InputCommand {
        switch action {
        case .keyboard:
            return .key(virtualKey: 6, text: "Z", flags: [])

        case .click:
            let point = try #require(target.clickPoint(), "the target has no clickable point")
            return .click(try target.location(of: point))

        case .scroll:
            let point = try #require(target.scrollPoint(), "the target has nothing to scroll")
            return .scroll(try target.location(of: point), deltaY: -6)

        case .drag:
            let path = try #require(target.dragEndpoints(), "the target has nothing to drag")
            return .drag(
                from: try target.location(of: path.start),
                to  : try target.location(of: path.end)
            )

        case .insertText:
            return .insertText(Self.insertedSample)

        case .paste:
            // Built here and not a Command of its own: the kit has no paste,
            // because a key equivalent is resolved by the frontmost
            // application's menu and the seat may never be frontmost.
            return .key(virtualKey: Self.vKeyCode, text: "v", flags: .maskCommand)
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

    /// Hands a window to the seat and makes sure it is on stage at full size
    /// before anything is posted to it.
    ///
    /// The move, the two agreeing window server readings and the raise are all
    /// the seat's now (`adopt`, `stage`). What is still the harness's is the
    /// decision that a stashed window has to be staged at all, because Stage
    /// Manager stashes whatever was on stage when a second window arrives and
    /// only the caller knows which of its targets it wants to act on next.
    private func adopt(
        _ target: any MatrixTarget,
        onto seat: AgentSeat,
        bounds   : CGRect
    ) async throws -> AdoptedWindow {

        var adopted = try await seat.adopt(
            target.fullSizeReference,
            platform: target.platform,
            title   : target.name
        )
        LivePump.run(for: 0.4)
        target.refresh()

        if !seat.isStaged(adopted) || !target.isStaged(within: bounds) {
            // Stage Manager stashed it on arrival. `stage` is `kAXRaiseAction`
            // plus two agreeing readings from the window server, and it is the
            // reason a Command is never posted at a thumbnail's coordinates.
            //
            // Timed here and not only in the benchmark: this is the one place a
            // window the person's own Stage Manager really stashed goes through
            // `stage`, and the budget of spec section 8 is written about
            // exactly that window (1 s p95, against 532 ms measured on
            // Chrome). The benchmark cannot manufacture the stash without
            // activating an application, which the kit must never do.
            let stashed = WindowServerProbe.geometry(of: target.window.windowNumber)?.frame
            let start   = DispatchTime.now().uptimeNanoseconds
            adopted = try await seat.stage(adopted)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            print(String(
                format: "stage: %@ came on stage in %.0f ms, from %@",
                target.name, Double(elapsed) / 1e6,
                String(describing: stashed ?? .null)
            ))
            #expect(
                elapsed <= 1_000_000_000,
                Comment(rawValue: "stage took \(elapsed / 1_000_000) ms, budget 1000 ms")
            )
            LivePump.run(for: 0.4)
        }
        target.refresh()

        let staged = WindowServerProbe.geometry(of: target.window.windowNumber)?.frame ?? .null
        #expect(
            target.isStaged(within: bounds),
            "\(target.name) never came on stage at full size: \(staged)"
        )
        return adopted
    }

    /// Two frames that agree within a couple of points, for deciding whether a
    /// window the seat already returned still needs putting back by hand.
    private func rectanglesMatchLoosely(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
    }

    private func restore(_ window: WindowReference, to origin: CGPoint) {
        do {
            try WindowRelocator.move(window, to: origin)
            LivePump.run(for: 0.5)
        } catch {
            Issue.record("could not put window \(window.windowNumber) back: \(error)")
        }
    }

    // MARK: The browser

    private func openProbePage(handingFocusBackTo person: UserSeatState) throws -> ChromeTarget? {
        guard let page = Bundle.module.url(forResource: "probe-page", withExtension: "html") else {
            Issue.record("probe-page.html is not in the test bundle")
            return nil
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments     = ["-g", "-a", ChromeTarget.ownerName, page.absoluteString]
        do {
            try open.run()
            open.waitUntilExit()
            try #require(open.terminationStatus == 0, "open returned \(open.terminationStatus)")
        } catch {
            Issue.record("Google Chrome could not be opened: \(error)")
            return nil
        }

        var target: ChromeTarget?
        _ = LivePump.run(
            until  : {
                target = ChromeTarget.find()
                return target != nil
            },
            timeout: 45
        )
        guard let target else {
            Issue.record("Chrome did not publish the probe page title \(ChromeTarget.titleMark) within 45 seconds")
            return nil
        }
        if NSRunningApplication(processIdentifier: target.processID)?.isActive == true,
           let previous = NSRunningApplication(processIdentifier: person.frontmostProcessID) {
            previous.activate()
            LivePump.run(for: 0.5)
        }
        print("chrome window \(target.windowNumber) of pid \(target.processID), \(target.diagnostics)")
        return target
    }

    private func quitChrome() {
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        quit.arguments     = ["-e", "tell application \"\(ChromeTarget.ownerName)\" to quit"]
        try? quit.run()
        quit.waitUntilExit()
    }

}

/// What the event stream carried during the run, which is the channel a
/// consumer reads its Issues and its recovery progress from.
@MainActor
final class SeatEventLog {
    private(set) var events: [SeatEvent] = []
    func record(_ event: SeatEvent) { events.append(event) }
}

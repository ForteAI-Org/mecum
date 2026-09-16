//
//  TextDeliveryLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore
import SeatInput
import SeatSession
import Testing
import WindowPlacement

/// Whether the two measurements in this file run. Both drive two applications
/// this suite launches for minutes at a time, which is a calibration and not an
/// acceptance gate, so both are off unless asked for.
nonisolated func textDeliverySkipReason() -> String? {
    liveSkipReason(
        optIn       : "AGENTSEAT_TEXT_DELIVERY",
        needsFixture: true,
        needsChrome : true
    )
}

/// ForcedPreparation answers the same thing for every Command, so a grid can
/// ask what a Command does **with** the Preparation and what it does without it
/// without asking the shipped policy first. It is test code on purpose: the
/// answer belongs in a platform, and a platform that took the answer as an
/// option would let a call site pick the one that does not work.
nonisolated struct ForcedPreparation: InputPlatform {

    let base  : any InputPlatform
    let forced: Preparation

    func preparation(for command: InputCommand) -> Preparation { forced }

    /// The platform's own settle unless `AGENTSEAT_TEXT_SETTLE_MS` names another
    /// one, which is how the grid was asked whether a Command that arrives only
    /// sometimes is waiting for the target to catch up.
    func preparationSettle(for command: InputCommand) -> Duration {
        guard let milliseconds = ProcessInfo.processInfo
            .environment["AGENTSEAT_TEXT_SETTLE_MS"].flatMap(Int.init)
        else {
            return base.preparationSettle(for: command)
        }
        return .milliseconds(milliseconds)
    }

    var dragPacing: DragPacing { base.dragPacing }
}

/// The states a target window can be in when a Command arrives. It is the
/// variable a preparation table indexed by Command cannot see, and an acceptance
/// run only ever visits one of them, so a policy written from such a run is only
/// sound if the state turns out not to matter. Holding it still, one state at a
/// time, is how that is checked instead of assumed.
enum WindowState: String, CaseIterable {

    /// The target's own application is the front one. Not a state the kit ever
    /// puts a target in, and here only as the control: if a Command behaves the
    /// same in front and behind, the window state is not what decides it.
    case frontmost

    /// Another application is in front and the window has never been raised,
    /// which is how a target sits before a seat touches it.
    case background

    /// Moved onto the Virtual Display by the seat, still in the background.
    case adopted

    /// Raised there with `kAXRaiseAction`, which does not activate the
    /// application, so still in the background.
    case raised
}

/// One cell: what was asked, in which state, with which Preparation, and what
/// the target itself says arrived.
nonisolated struct DeliveryRow {

    let target      : String
    let state       : String
    let command     : String
    let preparation : String
    let expected    : Int
    let characters  : Int
    let edits       : Int
    let milliseconds: Double
    let handSeen    : Bool

    /// Whether the target's own application was the front one while the Command
    /// was in flight. It is the column the historic reading did not have.
    let frontIsTarget: Bool

    /// Whether the window server was showing a thumbnail of the window instead
    /// of the window. Stage Manager stashes an inactive window on a physical
    /// display, and a stashed target refuses a Command the same window takes at
    /// full size, so a row that failed against a thumbnail says nothing about
    /// the Command.
    let windowIsStashed: Bool

    let detail      : String

    var arrived: Bool { characters == expected }

    /// A hand on the machine can move the focus out from under a Command, so a
    /// row that did not arrive while the person was typing proves nothing. A
    /// row that arrived exactly is still a pass: the hand can add, not deliver.
    var isInconclusive: Bool { (handSeen || windowIsStashed) && !arrived }

    var verdict: String { isInconclusive ? "INCO" : (arrived ? "PASS" : "FAIL") }

    var line: String {
        String(
            format: "| %-8@ | %-10@ | %-10@ | %-21@ | %-5@ | %-5@ | %4d | %6d | %5d | %7.0f | %-4@ |",
            target, state, command, preparation, frontIsTarget ? "self" : "other",
            windowIsStashed ? "stash" : "full",
            expected, characters, edits, milliseconds, verdict
        )
    }

    static let header = """
        | target   | state      | command    | preparation           | front | shown | want | chars  | edits |   ms  | fx   |
        |----------|------------|------------|-----------------------|-------|-------|------|--------|-------|-------|------|
        """
}

/// One run of the cost comparison: the same string, one verb against the other.
nonisolated struct InsertionRow {

    let target      : String
    let verb        : String
    let length      : Int
    let events      : Int
    let postedMs    : Double
    let totalMs     : Double
    let characters  : Int
    let edits       : Int
    let handSeen    : Bool

    var complete           : Bool   { characters >= length }
    var millisecondsPerChar: Double { totalMs / Double(length) }

    var line: String {
        String(
            format: "| %-8@ | %-10@ | %5d | %6d | %9.1f | %9.1f | %7.3f | %5d | %-5@ |",
            target, verb, length, events, postedMs, totalMs, millisecondsPerChar, edits,
            complete ? (handSeen ? "HAND" : "ok") : "SHORT"
        )
    }

    static let header = """
        | target   | verb       | chars | events | posted ms |  total ms |  ms/ch | edits | state |
        |----------|------------|-------|--------|-----------|-----------|--------|-------|-------|
        """
}

/// How a string reaches a background target: which Preparation it needs, and
/// what the two verbs that carry one cost.
///
/// Two measurements, and they answer two questions that turned out to be the
/// same question seen from different sides.
///
/// The first is the preparation grid. `InputPlatform.preparation(for:)` is a
/// table indexed by Command, and a table indexed by Command can only be right if
/// the answer does not also depend on where the window is: a policy cannot see
/// that. So the grid holds the window state still, four states from frontmost to
/// raised on the Virtual Display, and asks every keyboard Command in each of
/// them, once with the Preparation and once without.
///
/// The answer it gives on this build is that the state moves nothing and the
/// event moves everything. A key event carrying one character passes everywhere,
/// prepared or not, on both families. A key event carrying more than one is
/// refused by a Chromium renderer in every state unless the Preparation went
/// first, and taken by a native target in every state without it. That is a
/// property of the Command, so the table can express it.
///
/// Two things the grid also had to separate out. A Chromium renderer that
/// refuses the bulk event still **receives** it, page and focused field both
/// counting the key down, so the only honest reading is the target's own
/// character count and the only honest wait is a deadline. And the Preparation
/// alone is not enough there: the settle after it decides, which is why the grid
/// takes `AGENTSEAT_TEXT_SETTLE_MS` and why the platform now answers the settle
/// per Command. A window the person's Stage Manager has stashed to a thumbnail
/// refuses the Command at every settle, so such a row is inconclusive here
/// rather than failed.
///
/// The second is the cost of the two verbs that carry a string, measured on the
/// path the shipped platform actually takes. Both numbers come from the
/// target's own counter and never from a receipt: a receipt says what was
/// posted, not what landed.
///
/// Two rules of method, inherited from the sweep next door and worth repeating.
/// Every wait is a **polling deadline** and never a fixed sleep, or the sleep is
/// what gets measured. And a reported total is bounded below by how often the
/// target publishes: the instrumented AppKit target publishes twice a second, so
/// anything it reports under about 500 ms means "at or under the floor" and the
/// true figure is smaller, while the browser page rewrites its title every 50 ms
/// and is that much sharper.
///
/// The knobs, all off by default:
///
/// - `AGENTSEAT_TEXT_DELIVERY=1` runs both;
/// - `AGENTSEAT_TEXT_LENGTHS` is the cost grid, comma separated;
/// - `AGENTSEAT_TEXT_TARGETS` is which families run, so one can be redone alone;
/// - `AGENTSEAT_TEXT_SAMPLE` is how many characters a grid cell carries;
/// - `AGENTSEAT_TEXT_REPEATS` is how many times each grid cell runs, which is
///   the only way to tell a Command that always arrives from one that usually
///   does;
/// - `AGENTSEAT_TEXT_SETTLE_MS` overrides the platform's settle for the grid;
/// - `AGENTSEAT_TYPING_TIMEOUT_S` is the ceiling on one cost run.
@Suite("How a string reaches a background target", .serialized)
@MainActor
struct TextDeliveryLiveTests {

    /// How long one grid cell may take before it is called undelivered. A cell
    /// that arrives at all arrives in well under a second at these lengths, so
    /// the ceiling is generous and a failing cell costs it.
    static let cellTimeout: Double = 3

    /// The string every grid cell carries. Short on purpose: the grid measures
    /// whether anything arrives, not how fast. `AGENTSEAT_TEXT_SAMPLE` moves it,
    /// which is how the grid was asked whether the answer depends on the length
    /// of the string rather than on the Command.
    static var sampleLength: Int { sweepNumbers("AGENTSEAT_TEXT_SAMPLE", [16]).first ?? 16 }

    /// How many times each cell runs. One is enough to see whether something
    /// arrives at all; more is how a cell that arrives *sometimes* is told from
    /// one that always does, which no single run can answer.
    static var repeats: Int { max(1, sweepNumbers("AGENTSEAT_TEXT_REPEATS", [1]).first ?? 1) }

    /// Which families run, comma separated, so one of them can be re-measured
    /// on its own: `AGENTSEAT_TEXT_TARGETS=chromium`.
    static var families: String {
        ProcessInfo.processInfo.environment["AGENTSEAT_TEXT_TARGETS"] ?? "appkit,chromium"
    }

    // MARK: The preparation grid

    @Test("what a keyboard Command needs is decided by the event, not by the window state",
          .enabled(if: textDeliverySkipReason() == nil,
                   Comment(rawValue: textDeliverySkipReason() ?? "")))
    func thePreparationGrid() async throws {

        LivePump.prepare()
        #expect(Permissions.preflight(.postEvent),     "Post Event is not granted to the test runner")
        #expect(Permissions.preflight(.accessibility), "Accessibility is not granted to the test runner")

        let personBefore = UserSeatState.capture()
        let driver       = try InputDriver(allowUnvalidatedBuild: true)

        let appKit   = FixtureTypingTarget()
        let chromium = try ChromiumTypingTarget.launched()
        defer {
            appKit.terminate()
            chromium.terminate()
            handBack(to: personBefore)
        }

        var targets: [any TypingTarget] = []
        if Self.families.contains("appkit") {
            #expect(appKit.reset(), "the instrumented target did not come up")
            targets.append(appKit)
        }
        if Self.families.contains("chromium") { targets.append(chromium) }

        let host = SeatHost(configuration: SeatHostConfiguration())
        var hostIsUp = false
        defer {
            if hostIsUp { Task { await host.stop() } }
        }
        try await host.start()
        hostIsUp = true
        let seat = try host.makeSeat()

        var rows  : [DeliveryRow] = []
        var marker: Int64 = 0x7100_0000

        for target in targets {
            let other = target === (appKit as AnyObject) ? chromium.processID : appKit.processID

            for state in WindowState.allCases {
                switch state {
                case .frontmost:
                    activate(target.processID)

                case .background:
                    activate(other)

                case .adopted:
                    do {
                        _ = try await seat.adopt(
                            fullSize(of: target),
                            platform: target.platform,
                            title   : target.name
                        )
                    } catch {
                        print("  \(target.name) could not be adopted: \(error)")
                        continue
                    }
                    // Adoption is `AXPosition` and moves nothing else, but the
                    // move can hand the focus over, so the state is asserted
                    // rather than assumed.
                    activate(other)

                case .raised:
                    guard let held = seat.adoptedWindows.first else { continue }
                    do { _ = try await seat.stage(held) }
                    catch {
                        let server = WindowServerProbe.geometry(of: held.id)?.frame ?? .null
                        print("  \(target.name) could not be raised: \(error); "
                            + "expected \(held.originalFrame.size), server \(server), "
                            + "display \(CGDisplayBounds(host.displayID ?? 0))")
                        continue
                    }
                    activate(other)
                }

                let stashed = isStashed(target)
                print(String(
                    format: "  %@ %@: window server frame %@, front %@, %@",
                    target.name, state.rawValue,
                    String(describing: WindowServerProbe
                        .geometry(of: target.window.windowNumber)?.frame ?? .null),
                    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
                    stashed ? "stashed to a thumbnail" : "shown at full size"
                ))

                for (label, command, expected) in Self.grid() {
                    for preparation in [Preparation.none, .internalAppKitState] {
                        for _ in 0..<Self.repeats {
                            marker += 1
                            rows.append(await cell(
                                command,
                                label      : label,
                                expected   : expected,
                                on         : target,
                                state      : state,
                                preparation: preparation,
                                stashed    : stashed,
                                driver     : driver,
                                marker     : marker
                            ))
                        }
                    }
                }

            }

            // The window goes home before the next family takes the display,
            // whether or not the states that put it there all ran.
            for held in seat.adoptedWindows {
                _ = await seat.release(held, .returnToUserSeat)
            }
            LivePump.run(for: 0.6)
        }

        print("\na star marks the answer the shipped platform gives for that Command")
        print(DeliveryRow.header)
        for row in rows {
            print(row.line)
            if !row.detail.isEmpty { print("      \(row.detail)") }
        }

        for _ in 0..<40 { await Task.yield() }
        let teardown = await host.stop()
        hostIsUp = false
        #expect(teardown.displayRemoved, "the virtual display was left online")

        #expect(rows.contains { !$0.handSeen },
                "every cell saw the person's hand, so the grid proves nothing")

        // The gate, and it is the one the old policy line would have failed:
        // whatever the shipped platform answers for a Command has to deliver in
        // **every** state a seat can put a window in, not in the one state the
        // measurement happened to run in. `frontmost` is excluded because the
        // kit never puts a target there.
        for row in rows where row.state != WindowState.frontmost.rawValue
            && row.preparation.hasSuffix("*") {
            if row.isInconclusive {
                Issue.record(Comment(rawValue: "\(row.target) \(row.state) \(row.command): "
                    + "inconclusive, "
                    + (row.windowIsStashed
                        ? "the window server was showing a thumbnail of the target"
                        : "the person's hand was on the machine")))
                continue
            }
            #expect(row.arrived, Comment(rawValue:
                "\(row.target) \(row.state) \(row.command) under the shipped policy: "
                    + "\(row.characters) of \(row.expected) characters"))
        }
    }

    // MARK: The cost of the two verbs

    @Test("a string carried on one key event costs what one edit costs",
          .enabled(if: textDeliverySkipReason() == nil,
                   Comment(rawValue: textDeliverySkipReason() ?? "")))
    func theInsertionCost() async throws {

        LivePump.prepare()
        #expect(Permissions.preflight(.postEvent), "Post Event is not granted to the test runner")

        let personBefore = UserSeatState.capture()
        let driver       = try InputDriver(allowUnvalidatedBuild: true)
        let lengths      = sweepNumbers("AGENTSEAT_TEXT_LENGTHS", [128, 1_024, 8_192])

        let appKit = FixtureTypingTarget()
        let chromium = try ChromiumTypingTarget.launched()
        defer {
            appKit.terminate()
            chromium.terminate()
            handBack(to: personBefore)
        }

        var rows  : [InsertionRow] = []
        var marker: Int64 = 0x7200_0000

        print("""
            \nthe AppKit target publishes twice a second, so a total it reports under about \
            500 ms is at the floor and the true figure is smaller; the browser page rewrites \
            its title every 50 ms
            \n\(InsertionRow.header)
            """)

        for target in [appKit as any TypingTarget, chromium] {
            for length in lengths {
                let text = TypingCostLiveTests.text(ofLength: length)
                for verb in ["insertText", "text"] {
                    marker += 1
                    let command: InputCommand = verb == "insertText"
                        ? .insertText(text)
                        : .text(text)
                    let row = await run(
                        command,
                        verb  : verb,
                        length: length,
                        on    : target,
                        other : target === (appKit as AnyObject)
                            ? chromium.processID
                            : appKit.processID,
                        driver: driver,
                        marker: marker
                    )
                    rows.append(row)
                    print(row.line)
                    if !row.complete { print("  short: \(target.diagnostics())") }
                }
            }
        }

        #expect(rows.contains { !$0.handSeen }, "every run saw the person's hand, so this proves nothing")
        #expect(rows.allSatisfy { $0.complete }, "a run did not deliver its whole string")

        // The claim the case exists for, asserted rather than admired: at the
        // longest length measured, one key event beats one pair per character
        // by an order of magnitude on both families.
        for target in Set(rows.map(\.target)) {
            guard let length = lengths.max(),
                  let inserted = rows.first(where: {
                      $0.target == target && $0.verb == "insertText" && $0.length == length
                  }),
                  let typed = rows.first(where: {
                      $0.target == target && $0.verb == "text" && $0.length == length
                  }),
                  !inserted.handSeen, !typed.handSeen
            else { continue }

            #expect(
                inserted.totalMs * 10 < typed.totalMs,
                Comment(rawValue: "\(target) at \(length): inserted \(inserted.totalMs) ms "
                    + "against typed \(typed.totalMs) ms, less than ten times apart")
            )
        }
    }

    // MARK: One cell, one run

    /// The three keyboard Commands whose Preparation the grid is about, with how
    /// many characters each should put into the target.
    private static func grid() -> [(String, InputCommand, Int)] {
        let sample = TypingCostLiveTests.text(ofLength: sampleLength)
        return [
            // `kVK_ANSI_Z`, and the character travels on the event too, so a
            // layout where Z is not at 6 still produces one character.
            ("key",        .key(virtualKey: 6, text: "z"), 1),
            ("text",       .text(sample),                  sampleLength),
            ("insertText", .insertText(sample),            sampleLength),
        ]
    }

    /// One cell of the grid: send once, then poll the target's own counter.
    private func cell(
        _ command  : InputCommand,
        label      : String,
        expected   : Int,
        on target  : any TypingTarget,
        state      : WindowState,
        preparation: Preparation,
        stashed    : Bool,
        driver     : InputDriver,
        marker     : Int64
    ) async -> DeliveryRow {

        let charactersBefore = target.charactersTaken()
        let editsBefore      = target.editsApplied()
        let frontmostBefore  = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let platform         = ForcedPreparation(base: target.platform, forced: preparation)
        var detail           = ""

        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await driver.send(
                command,
                to           : target.window,
                correlationID: marker,
                platform     : platform
            )
        } catch {
            detail += " send refused: \(error)"
        }

        var characters = 0
        _ = LivePump.run(
            until  : {
                characters = target.charactersTaken() - charactersBefore
                return characters >= expected
            },
            timeout: Self.cellTimeout
        )
        let elapsed = Self.millisecondsSince(start)
        let edits   = target.editsApplied() - editsBefore
        if characters != expected { detail += " " + target.diagnostics() }

        // The shipped answer is named on the row rather than compared later: a
        // grid whose point is a policy has to say which cell is the policy.
        let shipped = target.platform.preparation(for: command) == preparation

        return DeliveryRow(
            target      : target.name,
            state       : state.rawValue,
            command     : label,
            preparation : preparation.rawValue + (shipped ? " *" : ""),
            expected    : expected,
            characters  : characters,
            edits       : edits,
            milliseconds : elapsed,
            handSeen     : secondsSinceHand() < elapsed / 1_000,
            frontIsTarget: frontmostBefore == target.processID,
            windowIsStashed: stashed,
            detail      : detail.trimmingCharacters(in: .whitespaces)
        )
    }

    /// One run of the cost comparison: empty the target, background it, send
    /// once, then poll until every character is there.
    private func run(
        _ command: InputCommand,
        verb     : String,
        length   : Int,
        on target: any TypingTarget,
        other    : pid_t,
        driver   : InputDriver,
        marker   : Int64
    ) async -> InsertionRow {

        // An editor that already holds thousands of characters costs more per
        // character than an empty one, so every run starts from empty, and the
        // target goes back to the background afterwards because that is the
        // only state the kit ever posts into.
        let ready = target.reset()
        activate(other)

        let charactersBefore = target.charactersTaken()
        let editsBefore      = target.editsApplied()
        var events           = 0
        var posted           = 0.0

        let start = DispatchTime.now().uptimeNanoseconds
        if ready {
            do {
                let receipt = try await driver.send(
                    command,
                    to           : target.window,
                    correlationID: marker,
                    platform     : target.platform
                )
                events = receipt.eventCount
                posted = Double(receipt.timing.postingNanoseconds) / 1_000_000
            } catch {
                print("  send refused: \(error)")
            }
        }

        var characters = 0
        _ = LivePump.run(
            until  : {
                characters = target.charactersTaken() - charactersBefore
                return characters >= length
            },
            timeout: TypingCostLiveTests.runTimeout
        )
        let total = Self.millisecondsSince(start)

        return InsertionRow(
            target    : target.name,
            verb      : verb,
            length    : length,
            events    : events,
            postedMs  : posted,
            totalMs   : total,
            characters: characters,
            edits     : target.editsApplied() - editsBefore,
            handSeen  : secondsSinceHand() < total / 1_000
        )
    }

    // MARK: The two applications this suite owns

    /// The identity to adopt by, with the size the target believes it has.
    ///
    /// The window server's size is a Stage Manager thumbnail for a window that
    /// was stashed, 99 by 116 points when it happened here, and adopting by that
    /// size places a thumbnail and then refuses to confirm the full size window
    /// that comes back. The application's own answer is the one to place by.
    private func fullSize(of target: any TypingTarget) -> WindowReference {
        let reference = target.window
        guard let believed = ChromeWindow.accessibilityFrame(
            processID   : reference.processID,
            windowNumber: reference.windowNumber
        ) else {
            return reference
        }
        return reference.replacingFrame(
            CGRect(origin: reference.frame.origin, size: believed.size)
        )
    }

    /// Whether the window server is showing a thumbnail rather than the window.
    /// The application answers with its own size whatever Stage Manager is
    /// doing, so the two readings disagreeing is the stash.
    private func isStashed(_ target: any TypingTarget) -> Bool {
        guard let server = WindowServerProbe
            .geometry(of: target.window.windowNumber)?.frame
        else {
            return false
        }
        return abs(server.width - fullSize(of: target).frame.width) > 2
    }

    /// Brings one of **this suite's own** processes to the front, which is how a
    /// window is put in the background without touching anything of the
    /// person's: the other target is always one this suite launched.
    private func activate(_ processID: pid_t) {
        NSRunningApplication(processIdentifier: processID)?.activate()
        LivePump.run(for: 0.6)
    }

    /// Puts the person's own front application back, because launching two
    /// applications took it away and nothing else here gives it back.
    private func handBack(to person: UserSeatState) {
        NSRunningApplication(processIdentifier: person.frontmostProcessID)?.activate()
        LivePump.run(for: 0.4)
    }

    private static func millisecondsSince(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }
}

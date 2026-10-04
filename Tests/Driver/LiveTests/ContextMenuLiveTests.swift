//
//  ContextMenuLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
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

/// The contextual menu on the Virtual Display: one native item and three
/// Chromium editing commands, each confirmed through the target's own effect.
///
/// The two questions this suite exists for are the two that decide whether the
/// primitive may ship at all.
///
/// **Does the menu stay inside the Virtual Display?** A menu is drawn, and a
/// menu drawn on the person's screen instead of on the seat's would make the
/// whole action visible interference. Measured here as a rectangle from the
/// window server, contained in the display the seat owns.
///
/// **Does the User Seat move while it is open?** A menu is a modal tracking
/// loop, and the frontmost application is the one thing a tracking loop could
/// plausibly disturb. It is sampled every 30 ms from before the click to after
/// the teardown, and the assertion is on the whole timeline: a reading taken
/// only before and after misses a transient, which is exactly how this
/// question was answered wrongly once.
///
/// The browser here is one **this suite launches**, on a profile of its own,
/// and not the person's. An open menu stops its application's event loop, and
/// that is not a thing to do to a window somebody is working in.
@Suite("The contextual menu on the Virtual Display", .serialized)
@MainActor
struct ContextMenuLiveTests {

    /// One family's outcome, printed as a row whatever it did.
    private struct Row {
        let family        : String
        var menuOpened    = false
        var appearedAfter : Duration = .zero
        var insideDisplay = false
        var frontmost     : [String] = []
        var closedBy      : String = "not reached"
        var reading       : String = "not read"
        var physicalEvents: UInt64 = 0
        var cursorMoved   = false
        var note          : String = ""

        /// Whether the seat put `targetActivated` on its own event stream, which
        /// is what it owes when an action costs the User Seat.
        var raisedTargetActivated = false

        var line: String {
            String(
                format: "| %-14@ | %-4@ | %-6@ | %-5@ | %-16@ | %@",
                family,
                menuOpened ? "OPEN" : "none",
                String(
                    format: "%.0f ms",
                    Double(appearedAfter.components.seconds) * 1000
                        + Double(appearedAfter.components.attoseconds) / 1e15
                ),
                insideDisplay ? "in" : "OUT",
                closedBy,
                reading
            )
        }
    }

    /// The frontmost application, sampled while something else is happening.
    /// It answers the distinct values in order, so a switch that lasted one
    /// sample is still in the list.
    @MainActor
    private final class FrontmostTimeline {

        private let start = Date()
        private var last  = ""

        /// Every change, with the millisecond it happened at and whatever step
        /// was marked last. A list of names alone cannot say whether a switch
        /// belongs to the action or to the adoption that preceded it, and that
        /// difference is the whole reading.
        private(set) var changes: [String] = []

        private var step = "start"
        private var observation: (any NSObjectProtocol)?

        init() {
            observation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let name = application?.localizedName ?? "?"
                let processID = application?.processIdentifier ?? -1
                // The observer runs on OperationQueue.main. Only value types
                // cross into the actor; the notification stays in its callback.
                MainActor.assumeIsolated {
                    self?.record(name: name, processID: processID)
                }
            }
        }

        func stop() {
            if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
            observation = nil
        }

        private(set) var values: [String] = []

        func mark(_ text: String) {
            step = text
            sample()
        }

        func sample() {
            let application = NSWorkspace.shared.frontmostApplication
            record(name: application?.localizedName ?? "?", processID: application?.processIdentifier ?? -1)
        }

        private func record(name applicationName: String, processID: pid_t) {
            let name = "\(applicationName)(\(processID))"
            guard name != last else { return }
            last = name
            values.append(name)
            changes.append(String(
                format: "%.0f ms %@ [%@]", Date().timeIntervalSince(start) * 1000, name, step
            ))
        }

        /// Samples every 30 ms for the given time, turning the run loop in
        /// between, which is the same cadence the primitive was measured with.
        func sample(for seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                LivePump.run(for: 0.03)
                sample()
            }
        }
    }

    @Test("a context menu opens on the Virtual Display, is used, and is closed, on both families",
          .enabled(if: liveSkipReason(needsFixture: true, needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(needsFixture: true, needsChrome: true) ?? "")))
    func theContextMenuMatrix() async throws {

        LivePump.prepare()
        #expect(Permissions.preflight(.postEvent),     "Post Event is not granted to the test runner")
        #expect(Permissions.preflight(.accessibility), "Accessibility is not granted to the test runner")

        let baselineOnline = Set(try DisplayList.online())
        let person         = UserSeatState.capture()
        var rows: [Row] = []
        print("the person has \(person.frontmostName)(\(person.frontmostProcessID)) in front")

        let host = SeatHost(configuration: SeatHostConfiguration())
        var hostIsUp = false
        defer { if hostIsUp { Task { await host.stop() } } }
        try await host.start()
        hostIsUp = true

        let seat = try host.makeSeat()

        // One listener for the whole run. An `AsyncStream` has one iterator, so
        // a task per family would split the events between them and each row
        // would see about half of what the seat said.
        let issues = IssueLog()
        let listening = Task { @MainActor in
            for await event in seat.events {
                if case .issueDetected(let issue, _) = event { issues.record(issue) }
            }
        }
        defer { listening.cancel() }

        let displayID     = try #require(host.displayID)
        let virtualBounds = CGDisplayBounds(displayID)
        let fence         = try #require(host.fence, "the host started without a fence")
        print("virtual display \(displayID) at \(virtualBounds)")

        // MARK: the AppKit family

        let fixture = try FixtureTarget.launched()
        defer { fixture.terminate() }


        rows.append(await measure(
            family : "AppKit fixture",
            seat   : seat,
            fence  : fence,
            bounds : virtualBounds,
            window : fixture.fullSizeReference,
            platform: AppKitPlatform(),
            issues : issues,
            pointIn: { _ in
                // The target's own button: a button has no contextual menu of
                // its own, so a right click on it reaches the content view's,
                // which the instrumented target built with one item. The point
                // is the one the target publishes and verifies its own hit test
                // against, so a row that misses is the target's defect and not
                // a coordinate this suite invented.
                fixture.refresh()
                guard let point = fixture.clickPoint() else { return nil }
                return try? fixture.location(of: point)
            },
            afterAdoption: { handFocusBack(from: fixture.window.processID, to: person) },
            // The native family exposes its menu, so the row chooses an item by
            // reading it rather than by aiming at the middle of a rectangle.
            choose : { menu, processID, windowNumber in
                Self.readAndChoose(
                    menu,
                    processID   : processID,
                    windowNumber: windowNumber,
                    titles      : ["Voce di prova"]
                )
            }
        ))
        fixture.terminate()
        LivePump.run(for: 0.6)

        // MARK: the Chromium family

        if OwnBrowserTarget.isAvailable {
            let browser = try OwnBrowserTarget.launched()
            defer { browser.terminate() }
            let browserWindow = try await adopt(
                browser.reference,
                onto    : seat,
                platform: ChromiumPlatform(),
                bounds  : virtualBounds
            )
            handFocusBack(from: browser.processID, to: person)

            let browserDriver = try InputDriver()
            let commands: [(name: String, titles: [String], seed: Bool, value: String, selection: Int?)] = [
                ("Select All", ["Select All", "Seleziona tutto"], false, "menu%20probe", 10),
                ("Undo", ["Undo", "Annulla"], true, "menu%20probe", nil),
                ("Redo", ["Redo", "Ripristina"], false, "changed", nil),
            ]
            for command in commands {
                rows.append(await measure(
                    family  : "Chrome \(command.name)",
                    seat    : seat,
                    fence   : fence,
                    bounds  : virtualBounds,
                    window  : browser.reference,
                    platform: ChromiumPlatform(),
                    issues  : issues,
                    pointIn : { staged in browser.probePoint(within: staged) },
                    stagedWindow: browserWindow,
                    beforeMenu: { adopted in
                        guard command.seed else { return }
                        // The preceding Select All gives this one edit an exact
                        // replacement. Undo and Redo must prove distinct contents.
                        _ = try await browserDriver.send(
                            .insertText("changed"),
                            to           : adopted.reference,
                            correlationID: 0,
                            platform     : ChromiumPlatform()
                        )
                        try #require(LivePump.run(
                            until: { Self.browserTitle(browser).contains(" v=changed - ") },
                            timeout: 2
                        ), "The controlled edit did not arrive; Undo has no proven prerequisite")
                    },
                    choose  : { menu, processID, windowNumber in
                        Self.readAndChoose(
                            menu,
                            processID   : processID,
                            windowNumber: windowNumber,
                            titles      : command.titles
                        )
                    }
                ))
                let effectArrived = LivePump.run(
                    until: {
                        let title = Self.browserTitle(browser)
                        guard title.contains(" v=\(command.value) - ") else { return false }
                        return command.selection.map { title.hasPrefix("ASMENU s=\($0) ") } ?? true
                    },
                    timeout: 2
                )
                let title = Self.browserTitle(browser)
                print("Chrome menu action, \(command.name): \(rows.last?.note ?? "no row")")
                print("Chrome menu effect, \(command.name): \(title)")
                try #require(effectArrived, "Chrome did not confirm \(command.name): \(title)")
            }
            _ = await seat.release(browserWindow, .returnToUserSeat)
            browser.terminate()
        } else {
            Issue.record("Google Chrome became unavailable at \(OwnBrowserTarget.executablePath)")
        }

        // MARK: the report and what it has to prove

        print("\n| family         | menu | at     | where | closed by        | what the tree said")
        for row in rows {
            print(row.line)
            if !row.note.isEmpty { print("      note: \(row.note)") }
            print("      frontmost, every change: \(row.frontmost)")
            print("      the seat reported targetActivated: \(row.raisedTargetActivated)")
            print("      physical events: \(row.physicalEvents), cursor moved: \(row.cursorMoved)")
        }

        let teardown = await host.stop()
        hostIsUp = false
        LivePump.run(for: 0.4)
        #expect(teardown.displayRemoved, "the virtual display was left online")
        #expect(Set(try DisplayList.online()) == baselineOnline, "a display was left behind")

        for row in rows {
            // A hand on the machine makes the row inconclusive and never a
            // pass: the person's own application switch is indistinguishable
            // from the anomaly this row is looking for.
            if row.physicalEvents > 0 {
                Issue.record(Comment(rawValue: """
                    \(row.family): inconclusive, \(row.physicalEvents) physical events during \
                    the action. Rerun without touching the machine.
                    """))
                continue
            }
            #expect(row.menuOpened, "\(row.family): no menu opened. \(row.note)")
            #expect(row.insideDisplay,
                    "\(row.family): the menu was drawn outside the Virtual Display")
            // Only the action's own samples: a switch that belongs to the
            // adoption before it is the matrix suite's question, not this one,
            // and folding the two together would blame the menu for it.
            let duringTheAction = row.frontmost.filter {
                $0.contains("[the menu action]") || $0.contains("[after the action]")
            }
            #expect(duringTheAction.isEmpty,
                    "\(row.family): a known test item changed the User Seat: \(row.frontmost)")
            #expect(!row.raisedTargetActivated,
                    "\(row.family): the known test item activated the target")
            #expect(!row.cursorMoved, "\(row.family): the menu action moved the person's cursor")
            #expect(row.closedBy == ContextMenuReceipt.Closure.chosenItem.rawValue,
                    "\(row.family): the identified item was not chosen: \(row.note)")
        }
    }

    // MARK: One family

    @Test(
        "owned Chromium context-menu Select All, Undo and Redo have observed effects",
        .enabled(
            if: ProcessInfo.processInfo.environment["AGENTSEAT_CHROMIUM_TESTS"] == "1"
                && liveSkipReason(needsChrome: true) == nil,
            "Opt in with AGENTSEAT_CHROMIUM_TESTS=1 on the approved exclusive desktop"
        )
    )
    func chromiumContextMenus() async throws {
        try await LiveStage.run(
            needsFixture : false,
            needsChrome  : false,
            configuration: SeatHostConfiguration(
                restoresUserFocus            : true,
                allowUnvalidatedFocusRecovery: true
            )
        ) { stage in
            let browser = try OwnBrowserTarget.launched()
            defer { browser.terminate() }
            _ = try WindowReader.windowSnapshot(
                processID   : browser.processID,
                windowNumber: browser.windowNumber
            )
            let window = try await adopt(
                browser.reference,
                onto    : stage.seat,
                platform: ChromiumPlatform(),
                bounds  : stage.virtualBounds
            )
            try handBackLiveFocus(
                to      : stage.personBefore,
                avoiding: browser.processID
            )
            let issues = IssueLog()
            let listening = Task { @MainActor in
                for await event in stage.seat.events {
                    if case .issueDetected(let issue, _) = event { issues.record(issue) }
                }
            }
            defer { listening.cancel() }
            let commands: [(name: String, titles: [String], seed: Bool, value: String, selection: Int?)] = [
                ("Select All", ["Select All", "Seleziona tutto"], false, "menu%20probe", 10),
                ("Undo", ["Undo", "Annulla"], true, "menu%20probe", nil),
                ("Redo", ["Redo", "Ripristina"], false, "changed", nil),
            ]
            for command in commands {
                let row = await measure(
                    family  : "Chrome \(command.name)",
                    seat    : stage.seat,
                    fence   : stage.fence,
                    bounds  : stage.virtualBounds,
                    window  : browser.reference,
                    platform: ChromiumPlatform(),
                    issues  : issues,
                    pointIn : { frame in browser.probePoint(within: frame) },
                    stagedWindow: window,
                    beforeMenu: { _ in
                        guard command.seed else { return }
                        let turn = try await stage.seat.acquire()
                        let receipt = try await stage.seat.send(
                            .insertText("changed"),
                            observation: try await liveObservation(stage.seat),
                            turn       : turn
                        )
                        let edited = LivePump.run(
                            until: { Self.browserTitle(browser).contains(" v=changed - ") },
                            timeout: 2
                        )
                        try stage.seat.confirm(
                            receipt,
                            edited ? .observed : .absent
                        )
                        _ = await stage.seat.concludeObservation()
                        try stage.seat.release(turn)
                        try #require(edited, "Undo requires a witnessed edit")
                    },
                    choose: { menu, processID, windowNumber in
                        Self.readAndChoose(
                            menu,
                            processID   : processID,
                            windowNumber: windowNumber,
                            titles      : command.titles
                        )
                    }
                )
                let arrived = LivePump.run(
                    until: {
                        let title = Self.browserTitle(browser)
                        guard title.contains(" v=\(command.value) - ") else { return false }
                        return command.selection.map { title.hasPrefix("ASMENU s=\($0) ") } ?? true
                    },
                    timeout: 2
                )
                print("CHROMIUM_CONTEXT \(command.name) effect=\(arrived) title=\(Self.browserTitle(browser))")
                print("CHROMIUM_CONTEXT \(row.line) \(row.reading) \(row.note)")
                #expect(row.menuOpened)
                #expect(row.insideDisplay)
                #expect(row.closedBy == ContextMenuReceipt.Closure.chosenItem.rawValue)
                #expect(row.physicalEvents == 0)
                #expect(!row.cursorMoved)
                #expect(!row.raisedTargetActivated)
                #expect(row.frontmost.count == 1, "The context menu changed foreground")
                #expect(
                    row.frontmost.first?.contains("(\(stage.personBefore.frontmostProcessID))") == true,
                    "The timeline's initial foreground was not the original user app"
                )
                try #require(arrived, "The selected context-menu item had no observed effect")
            }
            #expect(UserSeatState.capture() == stage.personBefore)
            #expect(stage.seat.currentTurn == nil)
            _ = await stage.seat.release(
                window,
                .returnToUserSeat
            )
        }
    }

    private func measure(
        family  : String,
        seat    : AgentSeat,
        fence   : CursorFence,
        bounds  : CGRect,
        window  : WindowReference,
        platform: any InputPlatform,
        issues  : IssueLog,
        pointIn : (CGRect) -> InputLocation?,
        stagedWindow: AdoptedWindow? = nil,
        afterAdoption: (() -> Void)? = nil,
        beforeMenu: ((AdoptedWindow) async throws -> Void)? = nil,
        choose  : @escaping (ContextMenu, pid_t, Int) -> (point: CGPoint?, reading: String)
    ) async -> Row {

        var row = Row(family: family)
        let timeline = FrontmostTimeline()
        defer { timeline.stop() }
        timeline.mark("before the target is adopted")

        let issuesBefore = issues.issues.count

        let adopted: AdoptedWindow
        do {
            if let stagedWindow { adopted = stagedWindow }
            else { adopted = try await adopt(window, onto: seat, platform: platform, bounds: bounds) }
        } catch {
            row.note = "the window was not adopted: \(error)"
            return row
        }

        // Stage a launched window before restoring the user's application;
        // a Space switch can remove the unstaged window from AXWindows.
        afterAdoption?()

        guard let staged = WindowServerProbe.geometry(of: adopted.id)?.frame else {
            row.note = "the window server lost the window after staging"
            return row
        }

        let handBefore = fence.snapshot().observedEventCount
        let cursorBefore = UserSeatState.capture().cursor
        timeline.mark("adopted and staged")

        guard let location = pointIn(staged) else {
            row.note = "the target published no point to aim at"
            return row
        }

        do {
            try await beforeMenu?(adopted)
            let turn = try await seat.acquire()
            var reading = "not read"

            timeline.mark("the menu action")
            let outcome = try await seat.withContextMenu(
                openedAt   : location,
                observation: try await liveObservation(seat),
                turn       : turn
            ) { interaction in
                timeline.sample()
                let answer = choose(interaction.menu, window.processID, adopted.id)
                reading = answer.reading
                guard let pointFromTop = answer.point else { return }

                // The item click needs an observation of the **menu's own**
                // surface from the kit. Where that ability is unqualified the
                // choice is not reached at all, and the reason is recorded
                // rather than replaced by a click the row aimed itself.
                switch await interaction.observe() {
                    case .failure(let refusal):
                        reading += "; the menu surface was not observable: \(refusal)"
                    case .success(let delivery):
                        let frame = delivery.geometry.window.frame
                        guard let point = InputLocation(
                            screenPoint: CGPoint(
                                x: frame.minX + pointFromTop.x,
                                y: frame.minY + pointFromTop.y
                            ),
                            observedIn : delivery.geometry
                        ) else {
                            reading += "; the point was outside the observed menu"
                            return
                        }
                        do {
                            _ = try await interaction.send(
                                .click(point, button: .left),
                                observation: delivery.reference
                            )
                        } catch {
                            reading += "; the item click was refused: \(error)"
                        }
                }
            }
            timeline.sample()

            row.menuOpened    = true
            row.appearedAfter = outcome.menu.appearedAfter
            row.insideDisplay = bounds.intersection(outcome.menu.frame) == outcome.menu.frame
            switch outcome.cleanup {
                case .verifiedClosed(let closure): row.closedBy = closure.rawValue
                case .notVerified(let reason)    : row.closedBy = "not verified: \(reason)"
            }
            row.reading       = reading
            row.note          = "target pid \(window.processID),"
                + " menu window \(outcome.menu.window.windowNumber) at \(outcome.menu.frame)"

            // Nothing to confirm: the action's own Commands are ones the seat
            // witnessed, so the hold comes straight back.
            #expect(seat.unconfirmedCommandCount == 0,
                    "\(family): the menu action left a Command for the caller to answer")
            _ = await seat.concludeObservation()
            do { try seat.release(turn) }
            catch { Issue.record("\(family): the hold was not given back: \(error)") }

        } catch {
            row.note = "\(error)"
            // The hold has to come back on every path out of here, or the next
            // family's `acquire` waits for it with no deadline. It can, because
            // a refused menu action leaves nothing unconfirmed behind it.
            if let turn = seat.currentTurn {
                _ = await seat.concludeObservation()
                do { try seat.release(turn) }
                catch { Issue.record("\(family): the hold was not given back: \(error)") }
            }
        }

        // The menu closes and the target keeps drawing, so the timeline runs on
        // past the action: a frontmost change that arrives late is still one.
        timeline.mark("after the action")
        timeline.sample(for: 0.4)
        for _ in 0 ..< 40 { await Task.yield() }
        row.raisedTargetActivated = issues.issues.dropFirst(issuesBefore)
            .contains(.targetActivated)
        row.frontmost      = timeline.changes
        row.physicalEvents = fence.snapshot().observedEventCount &- handBefore
        row.cursorMoved    = UserSeatState.capture().cursor != cursorBefore

        if stagedWindow == nil { _ = await seat.release(adopted, .returnToUserSeat) }
        LivePump.run(for: 0.4)
        return row
    }

    /// Chooses the requested item in either target. Unreadable
    /// menus are observed through their image; unidentified items are never
    /// replaced by a click at the centre, which can dispatch Print.
    private static func readAndChoose(
        _ menu      : ContextMenu,
        processID   : pid_t,
        windowNumber: Int,
        titles      : [String]
    ) -> (point: CGPoint?, reading: String) {

        let observed = (try? WindowReader.contextMenu(
            processID: processID, windowNumber: windowNumber
        )) ?? .notOpen

        switch observed {
            case .items(let items):
                let matches = items.filter { item in
                    item.isEnabled && titles.contains { $0.lowercased() == item.title.lowercased() }
                }
                guard matches.count == 1, let chosen = matches.first,
                      let frame = chosen.frame
                else {
                    Issue.record("The requested menu item \(titles) has no unique usable rectangle")
                    return (nil, "the requested item was not identified")
                }
                return (
                    CGPoint(x: frame.midX - menu.frame.minX, y: frame.midY - menu.frame.minY),
                    "\(items.map(\.title)) chose '\(chosen.title)' at \(frame)"
                )

            case .drawnOutsideTheAccessibilityTree:
                do {
                    let point = try MenuImageChoice.point(for: titles, in: menu.window)
                    return (point, "\(titles), identified in the menu image at \(point)")
                } catch {
                    Issue.record("The Chromium menu item could not be identified: \(error)")
                    return (nil, "\(titles) was not identified; no item clicked")
                }

            case .notOpen:
                // The reader disagrees with the seat's own oracle, which is a
                // finding and not a reason to click blindly.
                return (nil, "the reader saw no menu at all")
        }
    }

    private static func browserTitle(_ browser: OwnBrowserTarget) -> String {
        ChromeWindow.accessibilityTitle(
            processID   : browser.processID,
            windowNumber: browser.windowNumber
        )
    }

    private func adopt(
        _ window: WindowReference,
        onto seat: AgentSeat,
        platform : any InputPlatform,
        bounds   : CGRect
    ) async throws -> AdoptedWindow {

        var adopted = try await seat.adopt(window, platform: platform, title: "menu target")
        LivePump.run(for: 0.4)
        if !seat.isStaged(adopted) {
            adopted = try await seat.stage(adopted)
            LivePump.run(for: 0.4)
        }
        return adopted
    }

    /// A target that came up in front of the person's own application hands the
    /// focus straight back: this suite is about a target that is **not** the
    /// front application, and one that is measures nothing.
    ///
    /// It puts back the application the person had in front when the run
    /// started, and never whichever application happens to be first in the
    /// list. Those are not the same thing, and picking the second is how a
    /// measurement activates an application the person was not using: it
    /// happened here once, and it read as the seat's own anomaly.
    private func handFocusBack(from processID: pid_t, to person: UserSeatState) {
        guard NSRunningApplication(processIdentifier: processID)?.isActive == true,
              let previous = NSRunningApplication(processIdentifier: person.frontmostProcessID)
        else {
            LivePump.run(for: 0.4)
            return
        }
        previous.activate()
        _ = LivePump.run(
            until  : { NSRunningApplication(processIdentifier: processID)?.isActive == false },
            timeout: 5
        )
        LivePump.run(for: 0.3)
    }
}

/// What the seat put on its event stream while one family's row ran.
@MainActor
final class IssueLog {
    private(set) var issues: [SeatIssue] = []
    func record(_ issue: SeatIssue) { issues.append(issue) }
}

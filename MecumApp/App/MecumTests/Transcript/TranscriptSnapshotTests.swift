//
//  TranscriptSnapshotTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Mecum

/// Draws the transcript offscreen into PNGs, for a person to look at. It
/// needs no window on screen and no Screen Recording grant: the view draws
/// into a bitmap with `cacheDisplay`. Gated by MECUM_SNAPSHOTS=1; the files go
/// to MECUM_SNAPSHOT_DIR, or to a folder under the temporary directory.
///
/// The controller renders the mascot itself through `MascotImages`, the same
/// renderer the app's sidebar and transcript use, so a PNG is what the app shows.
@Suite("Transcript snapshots", .enabled(if: ProcessInfo.processInfo.environment["MECUM_SNAPSHOTS"] == "1"))
@MainActor
struct TranscriptSnapshotTests {

    private var directory: URL {
        get throws {
            let environment = ProcessInfo.processInfo.environment
            let directory   = environment["MECUM_SNAPSHOT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? URL.temporaryDirectory.appending(path: "MecumTranscriptSnapshots", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    @Test("Short and long messages, a tool burst and an interrupted answer, at two widths and both themes")
    func snapshots() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await conversation(fixture)

        for width in [480.0, 900.0] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await write(fixture, width: width, appearance: appearance,
                                to: try directory.appending(path: "transcript-\(Int(width))-\(name).png"))
            }
        }
    }

    @Test("A rich reply: headings, nested lists, a long code block, inline code, a quote, a table and a link")
    func richSnapshots() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Where are we with the release?", at: 0)
        try await fixture.say(TranscriptFixture.richReply, at: 10, byWorker: true)

        for width in [480.0, 900.0] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await write(fixture, width: width, appearance: appearance,
                                to: try directory.appending(path: "transcript-rich-\(Int(width))-\(name).png"))
            }
        }
    }

    @Test("An interrupted turn and a failed turn, so both delivery badges show")
    func badges() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let stopped = UUID(), failed = UUID()
        try await fixture.say("Rename the release branch.", at: 0, delivery: .interrupted)
        try await fixture.record(.executionStarted, subject: stopped, at: 1)
        try await fixture.record(.toolActivity, subject: stopped, at: 2, text: "→ list_branches {}")
        try await fixture.say("Looking at the branches, the release one is", at: 3, byWorker: true)
        try await fixture.record(.executionCancelled, subject: stopped, at: 4,
                                 text: "Stopped. Review the app before continuing.")
        try await fixture.say("Try again, and push it this time.", at: 400, delivery: .interrupted)
        try await fixture.record(.executionStarted, subject: failed, at: 401)
        try await fixture.record(.toolActivity, subject: failed, at: 402, text: "→ push {\"branch\":\"release\"}")
        try await fixture.record(.toolActivity, subject: failed, at: 403, text: "← push error: remote refused")
        try await fixture.record(.executionFailed, subject: failed, at: 404,
                                 text: "The provider stopped with exit status 1.")
        try await fixture.say("Leave it for now.", at: 800, delivery: .savedLocally)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await write(fixture, width: 600, appearance: appearance,
                            to: try directory.appending(path: "transcript-badges-600-\(name).png"))
        }
    }

    @Test("Scrolled up while three messages arrive, then a change to a row already seen: both indicator pills")
    func indicatorSnapshots() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        var waiting: [MessageSnapshot] = []
        for index in 0..<30 {
            let message = try await fixture.say("Message \(index), with a little more text to give it a line or two.",
                                                at: Double(index) * 400, byWorker: index % 2 == 1,
                                                delivery: index >= 26 ? .sentToBackend : .completed)
            if index == 26 || index == 28 { waiting.append(message) }
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let controller = TranscriptController(source: fixture.store)
            let backdrop   = Backdrop(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
            backdrop.appearance = NSAppearance(named: appearance)
            controller.view.frame = backdrop.bounds
            backdrop.addSubview(controller.view)
            let window = TranscriptFixture.offscreenWindow(for: backdrop, size: backdrop.frame.size)
            defer { window.close() }
            controller.bottomInset = 60
            controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                            readingAnchor: nil, readingOffset: 0)
            await controller.settle()
            controller.setVisibleTop(400)
            try await fixture.store.update(message: waiting.removeFirst().id, delivery: .completed)
            controller.refresh()
            await controller.settle()
            backdrop.layoutSubtreeIfNeeded()
            let updates = try directory.appending(path: "transcript-updates-600-\(name).png")
            try Self.png(of: backdrop).write(to: updates)
            print("snapshot: \(updates.path)")

            for index in 0..<3 {
                try await fixture.say("Arrived \(index) (\(name)).", at: 100_000 + Double(index), byWorker: true)
            }
            controller.refresh()
            await controller.settle()
            backdrop.layoutSubtreeIfNeeded()
            let file = try directory.appending(path: "transcript-new-messages-600-\(name).png")
            try Self.png(of: backdrop).write(to: file)
            print("snapshot: \(file.path)")
        }
    }

    @Test("A selection from the middle of one message to the middle of the next, across the header between")
    func selectionSnapshot() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Can you check this morning's build and tell me what failed?", at: 0)
        try await fixture.say("""
            The build finished at 07:42. Two bundles failed: the capture suite timed out once on the \
            virtual display, and the layout suite failed on a width assertion.
            """, at: 10, byWorker: true)
        try await fixture.say("Rerun the capture suite first.", at: 20)

        let spanning: @MainActor (TranscriptController) -> Void = { controller in
            let messages = controller.rows.filter { $0.item.messageID != nil }
            guard messages.count >= 2 else { return }
            let (first, second) = (messages[0], messages[1])
            controller.select(TranscriptSelection(anchor: .init(itemID: first.item.id, offset: 14),
                                                  focus : .init(itemID: second.item.id, offset: 60)))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await write(fixture, width: 600, appearance: appearance,
                            to: try directory.appending(path: "transcript-selection-600-\(name).png"),
                            adjust: spanning)
        }
    }

    @Test("Two days, grouped tails, a thinking bubble, tool lines collapsed and expanded, a failed step, code")
    func contentSnapshots() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await twoDays(fixture)

        // The second tool line, whose step failed, opened as a click would.
        let expanding: @MainActor (TranscriptController) -> Void = { controller in
            let lines = controller.rows.indices.filter {
                if case .toolRun = controller.rows[$0].item.kind { true } else { false }
            }
            guard lines.count >= 2,
                  let cell = controller.collectionView.item(at: IndexPath(item: lines[1], section: 0)) as? TranscriptCell
            else { return }
            cell.rowView.onActivate?()
        }
        // From the middle of the person's first message to the middle of their third.
        let selecting: @MainActor (TranscriptController) -> Void = { controller in
            let people = controller.rows.filter { $0.item.authorWorkerID == nil && $0.item.messageID != nil }
            guard people.count >= 3 else { return }
            controller.select(TranscriptSelection(anchor: .init(itemID: people[0].item.id, offset: 12),
                                                  focus : .init(itemID: people[2].item.id, offset: 10)))
        }
        for width in [600.0, 900.0] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await write(fixture, width: width, appearance: appearance,
                                to: try directory.appending(path: "content-\(Int(width))-\(name).png"))
                try await write(fixture, width: width, appearance: appearance,
                                to: try directory.appending(path: "content-expanded-\(Int(width))-\(name).png"),
                                adjust: expanding)
            }
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await write(fixture, width: 600, appearance: appearance,
                            to: try directory.appending(path: "content-selection-600-\(name).png"), adjust: selecting)
        }
    }

    /// Yesterday evening and today just after midnight, in the reader's time
    /// zone: a group of three, a worker group of two, a failed step, the
    /// person's code, a reply with Swift and Python, and a turn still running.
    private func twoDays(_ fixture: TranscriptFixture) async throws {
        let midnight = Calendar.autoupdatingCurrent.startOfDay(for: Date()).timeIntervalSince(TranscriptFixture.origin)
        let (first, second, third, fourth) = (UUID(), UUID(), UUID(), UUID())
        var clock = midnight - 1200
        func tool(_ turn: UUID, _ text: String) async throws {
            clock += 0.5
            try await fixture.record(.toolActivity, subject: turn, at: clock, text: text)
        }

        try await fixture.say("Can you open Calculator and add 8 and 5?", at: midnight - 1200)
        try await fixture.say("Use the keypad, not the menu.", at: midnight - 1195)
        try await fixture.say("And tell me the result.", at: midnight - 1190)
        clock = midnight - 1189
        try await fixture.record(.executionStarted, subject: first, at: clock)
        try await tool(first, "→ status {}")
        try await tool(first, "← status {\"session\":null}")
        try await tool(first, "→ open_session {\"app\":\"Calculator\"}")
        try await tool(first, "← open_session {\"session\":\"s\"}")
        for key in ["8", "+", "5", "="] {
            try await tool(first, "→ act {\"session\":\"s\",\"target\":\"\(key)\"}")
            try await tool(first, "← act {\"status\":\"found_acted\",\"message\":\"ok\"}")
        }
        for _ in 0..<3 {
            try await tool(first, "→ observe {\"session\":\"s\"}")
            try await tool(first, "← observe {\"scene\":\"…\"}")
        }
        try await fixture.say("Calculator is open, and I pressed 8, +, 5 and = on the keypad.", at: midnight - 1170,
                              byWorker: true)
        try await fixture.say("The display shows **13**.", at: midnight - 1169, byWorker: true)
        try await fixture.record(.executionCompleted, subject: first, at: midnight - 1168)

        try await fixture.say("Now set the size to Large.", at: midnight - 600)
        clock = midnight - 599
        try await fixture.record(.executionStarted, subject: second, at: clock)
        try await tool(second, "→ observe {\"session\":\"s\"}")
        try await tool(second, "← observe {\"scene\":\"…\"}")
        try await tool(second, "→ select {\"session\":\"s\",\"control\":\"Size\",\"item\":\"Large\"}")
        try await tool(second, "← select error: No control named Size on this screen. Observe before any retry.")
        try await fixture.say("Calculator's window has no Size control, so nothing was changed.", at: midnight - 590,
                              byWorker: true)
        try await fixture.record(.executionCompleted, subject: second, at: midnight - 589)

        try await fixture.say("""
            Why does this not compile?

            ```swift
            let total = [8, 5].reduce(0, +)
            print("total: \\(total)")
            ```
            It says `reduce` is ambiguous, and *this* stays literal.
            """, at: midnight + 300)
        try await fixture.record(.executionStarted, subject: third, at: midnight + 301)
        try await fixture.say("""
            The literal `[8, 5]` has no element type the compiler can pick for `+`. Name it:

            ```swift
            // An explicit element type settles the overload.
            let total: Int = [8, 5].reduce(0, +)
            print("total: \\(total)")
            ```

            The same sum in Python needs no annotation:

            ```python
            # sum() starts from 0
            total = sum([8, 5])
            print(f"total: {total}")
            ```
            """, at: midnight + 320, byWorker: true)
        try await fixture.record(.executionCompleted, subject: third, at: midnight + 321)

        try await fixture.say("Thanks. Close Calculator now.", at: midnight + 480)
        clock = midnight + 481
        try await fixture.record(.executionStarted, subject: fourth, at: clock)
        try await tool(fourth, "→ observe {\"session\":\"s\"}")
        try await tool(fourth, "← observe {\"scene\":\"…\"}")
        try await tool(fourth, "→ close_session {\"session\":\"s\"}")
    }

    @Test("A tool line collapsed and opened: a step that failed then worked, a long label, a turn still running")
    func toolLineSnapshots() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let (sent, next) = (UUID(), UUID())
        var records = ToolLineTests.slack
        records.insert(contentsOf: [
            "→ act {\"session\":\"s\",\"target\":\"India • (Lista delle chat)\",\"section\":\"content (Chat)\"}",
            "← act {\"status\":\"found_acted\"}",
        ], at: 6)
        try await fixture.say("Scrivi a India su Slack: ci vediamo alle 15?", at: 0)
        try await fixture.record(.executionStarted, subject: sent, at: 1)
        for (offset, record) in records.enumerated() {
            try await fixture.record(.toolActivity, subject: sent, at: 2 + Double(offset) * 0.1, text: record)
        }
        try await fixture.say("I sent India your message on Slack.", at: 5, byWorker: true)
        try await fixture.record(.executionCompleted, subject: sent, at: 6)
        try await fixture.say("Thanks. Now check my calendar for today.", at: 60)
        try await fixture.record(.executionStarted, subject: next, at: 61)
        try await fixture.record(.toolActivity, subject: next, at: 62, text: "→ open_session {\"app\":\"Calendar\"}")

        // The Slack turn's line opened, as a click would.
        let expanding: @MainActor (TranscriptController) -> Void = { controller in
            guard let index = controller.rows.firstIndex(where: {
                      if case .toolRun = $0.item.kind { true } else { false }
                  }),
                  let cell = controller.collectionView.item(at: IndexPath(item: index, section: 0)) as? TranscriptCell
            else { return }
            cell.rowView.onActivate?()
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await write(fixture, width: 600, appearance: appearance,
                            to: try directory.appending(path: "tool-line-collapsed-600-\(name).png"))
            try await write(fixture, width: 600, appearance: appearance,
                            to: try directory.appending(path: "tool-line-expanded-600-\(name).png"), adjust: expanding)
        }
        // At the largest text size a summary that would wrap is cut short on its one line.
        try await write(fixture, width: 480, appearance: .aqua,
                        to: try directory.appending(path: "tool-line-collapsed-480-24pt-light.png"),
                        style: TranscriptStyle(bodyPointSize: 24))
    }

    @Test("Three messages selected as bubbles, the person's and two of the worker's, beside one that is not")
    func bubbleSnapshots() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Can you check this morning's build and tell me what failed?", at: 0)
        try await fixture.say("The build finished at 07:42. Two bundles failed.", at: 10, byWorker: true)
        try await fixture.say("The capture suite timed out once; the layout suite failed on a width.", at: 12,
                              byWorker: true)
        try await fixture.say("Rerun the capture suite first.", at: 20)

        let chosen: @MainActor (TranscriptController) -> Void = { controller in
            // By message, not by row: the day separator opens the conversation.
            let messages = controller.rows.filter { $0.item.messageID != nil }
            guard messages.count >= 3 else { return }
            controller.click(messages[0].item.id, modifiers: [])
            controller.click(messages[2].item.id, modifiers: .shift)
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await write(fixture, width: 600, appearance: appearance,
                            to: try directory.appending(path: "transcript-bubbles-600-\(name).png"),
                            adjust: chosen)
        }
    }

    // MARK: Drawing

    /// Measures at an ordinary height, then draws tall enough that every row is
    /// on screen, so the recycled view has made a cell for each.
    private func write(
        _ fixture : TranscriptFixture,
        width     : CGFloat,
        appearance: NSAppearance.Name,
        to file   : URL,
        adjust    : (@MainActor (TranscriptController) -> Void)? = nil,
        style     : TranscriptStyle = TranscriptStyle()
    ) async throws {
        let measuring = try await render(fixture, width: width, height: 600, appearance: appearance, adjust: adjust,
                                         style: style)
        let backdrop  = try await render(fixture, width: width, height: measuring.contentHeight,
                                         appearance: appearance, adjust: adjust, style: style).backdrop
        try Self.png(of: backdrop).write(to: file)
        print("snapshot: \(file.path)")
    }

    private func render(
        _ fixture : TranscriptFixture,
        width     : CGFloat,
        height    : CGFloat,
        appearance: NSAppearance.Name,
        adjust    : (@MainActor (TranscriptController) -> Void)? = nil,
        style     : TranscriptStyle = TranscriptStyle()
    ) async throws -> (backdrop: NSView, contentHeight: CGFloat) {
        let controller = TranscriptController(source: fixture.store, style: style)
        let backdrop   = Backdrop(frame: NSRect(x: 0, y: 0, width: width, height: height))
        backdrop.appearance = NSAppearance(named: appearance)
        controller.view.frame = backdrop.bounds
        backdrop.addSubview(controller.view)
        backdrop.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        adjust?(controller)
        // An adjustment may queue a projection, such as a tool line expanding.
        await controller.settle()
        backdrop.layoutSubtreeIfNeeded()
        return (backdrop, controller.contentHeight)
    }

    /// The synthetic conversation the four width and theme snapshots draw.
    private func conversation(_ fixture: TranscriptFixture) async throws {
        let first = UUID(), second = UUID()
        try await fixture.say("Can you check this morning's build?", at: 0)
        try await fixture.say("And tell me if anything failed.", at: 10)
        try await fixture.record(.executionStarted, subject: first, at: 12)
        for step in 0..<8 {
            try await fixture.record(.toolActivity, subject: first, at: 13 + Double(step),
                                     text: "→ read_log {\"step\":\(step)}")
            try await fixture.record(.toolActivity, subject: first, at: 13.5 + Double(step),
                                     text: step == 5 ? "← read_log error: file is locked" : "← read_log {\"ok\":true}")
        }
        try await fixture.say("Done.", at: 30, byWorker: true)
        try await fixture.say("""
            The build finished at 07:42 and every target compiled. Two test bundles reported failures: \
            the capture suite timed out once on the virtual display, which matches the flake we saw last \
            week, and the layout suite failed on a width assertion that started after yesterday's change \
            to the sidebar.

            I would rerun the capture suite before looking deeper, and open the layout failure first, \
            since it is new and it points at one commit.
            """, at: 32, byWorker: true)
        try await fixture.record(.executionCompleted, subject: first, at: 34)
        try await fixture.say("Open the layout failure and fix it.", at: 400, delivery: .interrupted)
        try await fixture.record(.executionStarted, subject: second, at: 401)
        try await fixture.say("Opening the failing assertion in", at: 403, byWorker: true)
        try await fixture.record(.executionCancelled, subject: second, at: 404,
                                 text: "Stopped. Review the app before continuing.")
        try await fixture.say("Sorry, stop there. Next time ask first.", at: 460, delivery: .savedLocally)
    }

    private static func png(of view: NSView) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotFailure.noBitmap
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotFailure.noPNG }
        return data
    }

    private enum SnapshotFailure: Error { case noBitmap, noPNG }
}

/// The window background behind the transcript, so a PNG reads as the app would.
private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

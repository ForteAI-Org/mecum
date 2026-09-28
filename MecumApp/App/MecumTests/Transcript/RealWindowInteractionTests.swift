//
//  RealWindowInteractionTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Mecum

/// The transcript in a real titled window ordered on screen, next to a view
/// standing in for the composer that holds the keyboard, driven by events and
/// actions rather than by the controller's methods. Copies go to a private
/// pasteboard. The stand-in is not a text view: a focused text view on screen
/// starts AppKit's inline text UI, which ends this helper process.
///
/// A test process cannot become the active app here (activating it ends the
/// helper), so NSWindow takes every left click as the one that would activate
/// it and drops it. A left mouse event therefore goes to the view the window's
/// hit test picks, as the window would send it; key events, right clicks and
/// actions go through the window and the responder chain.
@Suite("Transcript in a real window", .serialized)
@MainActor
struct RealWindowInteractionTests {

    /// The transcript above a stand-in composer that holds the keyboard.
    private struct Stage {
        let controller: TranscriptController
        let window    : NSWindow
        let composer  : NSView
    }

    private func stage(_ fixture: TranscriptFixture, pasteboard: NSPasteboard, height: CGFloat = 500) async
        -> Stage {
        _ = NSApplication.shared
        let controller = TranscriptController(source: fixture.store, pasteboard: pasteboard)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 600, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content  = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        let composer = KeyboardHolder(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        controller.view.frame = NSRect(x: 0, y: 40, width: 600, height: height - 40)
        controller.view.autoresizingMask = [.width, .height]
        content.addSubview(controller.view)
        content.addSubview(composer)
        window.contentView = content
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(composer)
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        content.layoutSubtreeIfNeeded()
        return Stage(controller: controller, window: window, composer: composer)
    }

    // MARK: Events

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow)
        throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    /// A left drag from `start` to `end`, in window coordinates.
    private func drag(from start: CGPoint, to end: CGPoint, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let target  = try #require(content.hitTest(content.convert(start, from: nil)))
        target.mouseDown(with: try mouse(.leftMouseDown, at: start, in: window))
        target.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: window))
        target.mouseUp(with: try mouse(.leftMouseUp, at: end, in: window))
    }

    /// A click without movement at `point`, in window coordinates.
    private func click(at point: CGPoint, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let target  = try #require(content.hitTest(content.convert(point, from: nil)))
        target.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window, modifiers: modifiers))
        target.mouseUp(with: try mouse(.leftMouseUp, at: point, in: window, modifiers: modifiers))
    }

    /// The window point `x` points into the first line of `row`'s block `block`.
    /// The row index of the `n`th message, counting from zero. Day separators
    /// and tool lines sit between messages, so a fixed row index would drift.
    private func messageRow(_ n: Int, of controller: TranscriptController) throws -> Int {
        let messages = controller.rows.indices.filter { controller.rows[$0].item.messageID != nil }
        return try #require(messages.dropFirst(n).first)
    }

    private func point(inRow index: Int, block: Int = 0, x: CGFloat, of controller: TranscriptController) throws
        -> CGPoint {
        let row   = controller.rows[index]
        let frame = try #require(controller.frameMap()[row.item.id])
        let text  = row.geometry.blockTexts[block]
        return controller.collectionView.convert(CGPoint(x: frame.minX + text.minX + x, y: frame.minY + text.minY + 5),
                                                 to: nil)
    }

    /// The menu AppKit gets for a right click at `point`: it asks the view its
    /// hit test picks. A menu presented in this helper process ends it within
    /// seconds, so the menu is asked for and not shown.
    private func rightClick(at point: CGPoint, in window: NSWindow) throws -> NSMenu? {
        let content = try #require(window.contentView)
        let target  = try #require(content.hitTest(content.convert(point, from: nil)))
        return target.menu(for: try mouse(.rightMouseDown, at: point, in: window))
    }

    // MARK: Copy

    @Test("A drag takes the keyboard from the composer; Command C and the Copy action copy the source text")
    func dragThenCopy() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        try await fixture.say("Check the **build** and tell me what failed.", at: 0)
        try await fixture.say("Two bundles failed: capture and layout.", at: 10, byWorker: true)
        let stage = await stage(fixture, pasteboard: pasteboard)
        defer { stage.window.close() }
        let controller = stage.controller
        #expect(stage.window.firstResponder === stage.composer)

        try drag(from: try point(inRow: try messageRow(0, of: controller), x: 0, of: controller),
                 to: try point(inRow: try messageRow(1, of: controller), x: 70, of: controller),
                 in: stage.window)
        #expect(stage.window.firstResponder === controller.collectionView, "the press moved the keyboard")
        let selection = try #require(controller.textSelection)
        let expected  = try #require(selection.span(in: controller.rows)?.text(in: controller.rows))
        #expect(expected.hasPrefix("Check the **build**"), "the person's source, not the drawn text")
        #expect(expected.contains(".\n\nTwo "))

        stage.window.sendEvent(try key(8, "c", .command, in: stage.window))
        #expect(pasteboard.string(forType: .string) == expected)

        pasteboard.clearContents()
        let copy = #selector(NSText.copy(_:))
        let sent = NSApp.keyWindow === stage.window
            ? NSApp.sendAction(copy, to: nil, from: nil)
            : stage.window.firstResponder?.tryToPerform(copy, with: nil) ?? false
        #expect(sent)
        #expect(pasteboard.string(forType: .string) == expected)

        // Nothing selected and a message focused: Copy takes the focused message.
        controller.select(nil)
        pasteboard.clearContents()
        #expect(stage.window.firstResponder?.tryToPerform(copy, with: nil) == true)
        #expect(pasteboard.string(forType: .string) == "Check the **build** and tell me what failed.")
    }

    // MARK: Tool lines

    @Test("A click on a tool line's summary opens its card, a click in the card leaves it open")
    func toolCardStaysOpenWhenClicked() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let turn = UUID()
        try await fixture.say("Compute 8", at: 0)
        try await fixture.record(.executionStarted, subject: turn, at: 1)
        try await fixture.record(.toolActivity, subject: turn, at: 2, text: "→ open_session {\"app\":\"Calculator\"}")
        try await fixture.record(.toolActivity, subject: turn, at: 3, text: "← open_session {}")
        try await fixture.record(.toolActivity, subject: turn, at: 4, text: "→ act {\"session\":\"s\",\"target\":\"8\"}")
        try await fixture.record(.toolActivity, subject: turn, at: 5, text: "← act {\"status\":\"found_acted\"}")
        try await fixture.say("8 is on the display.", at: 6, byWorker: true)
        try await fixture.record(.executionCompleted, subject: turn, at: 7)
        let stage = await stage(fixture, pasteboard: pasteboard)
        defer { stage.window.close() }
        let controller = stage.controller

        func toolRow() throws -> Int {
            try #require(controller.rows.firstIndex { if case .toolRun = $0.item.kind { true } else { false } })
        }
        func isOpen() throws -> Bool {
            guard case .toolRun(_, let isExpanded, _) = controller.rows[try toolRow()].item.kind else { return false }
            return isExpanded
        }

        try click(at: try point(inRow: try toolRow(), x: 10, of: controller), in: stage.window)
        await controller.settle()
        #expect(try isOpen(), "the summary opens the card")

        try click(at: try point(inRow: try toolRow(), block: 1, x: 10, of: controller), in: stage.window)
        await controller.settle()
        #expect(try isOpen(), "a click in the card leaves it open")

        try click(at: try point(inRow: try toolRow(), x: 10, of: controller), in: stage.window)
        await controller.settle()
        #expect(try !isOpen(), "the summary folds it again")
    }

    // MARK: Context menu

    @Test("A right click gives the row's menu: Copy Message copies, a link and a code block add their items")
    func contextMenu() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        try await fixture.say("Where are the notes?", at: 0)
        let reply = "Read [the notes](https://example.com/notes) first.\n\n```sh\nmake test\n```"
        try await fixture.say(reply, at: 10, byWorker: true)
        let stage = await stage(fixture, pasteboard: pasteboard)
        defer { stage.window.close() }
        let controller = stage.controller
        let window     = stage.window

        // On the person's bubble: the message's own items, and a right click takes the keyboard.
        let onQuestion = try point(inRow: try messageRow(0, of: controller), x: 10, of: controller)
        let plain = try #require(try rightClick(at: onQuestion, in: window))
        #expect(plain.items.map(\.title) == ["Reply", "Copy Message", "Select Message"])
        #expect(window.firstResponder === controller.collectionView)
        plain.performActionForItem(at: 1)
        #expect(pasteboard.string(forType: .string) == "Where are the notes?")

        // Inside a selection, the selection stays and Copy leads.
        let row = controller.rows[try messageRow(1, of: controller)]
        controller.select(TranscriptSelection(anchor: .init(itemID: row.item.id, offset: 0),
                                              focus : .init(itemID: row.item.id, offset: 14)))
        let chosen = controller.textSelection
        let onLink = try point(inRow: try messageRow(1, of: controller), x: 40, of: controller)
        let linked = try #require(try rightClick(at: onLink, in: window))
        #expect(linked.items.map(\.title) == ["Copy", "Reply", "Copy Message", "Select Message", "Open Link",
                                               "Copy Link"])
        #expect(controller.textSelection == chosen)
        linked.performActionForItem(at: 5)
        #expect(pasteboard.string(forType: .string) == "https://example.com/notes")

        // On the code block, outside the selection: the selection goes, Copy Code comes.
        let code = try #require(row.text.blocks.firstIndex { $0.isCompleteCode })
        let onCode = try point(inRow: try messageRow(1, of: controller), block: code, x: 12, of: controller)
        let coded = try #require(try rightClick(at: onCode, in: window))
        #expect(coded.items.map(\.title) == ["Reply", "Copy Message", "Select Message", "Copy Code"])
        #expect(controller.textSelection == nil)
        coded.performActionForItem(at: 3)
        #expect(pasteboard.string(forType: .string) == "make test")
        coded.performActionForItem(at: 2)
        #expect(controller.bubbleSelection == [try #require(row.item.messageID)])

        // From the keyboard: Shift F10 and the context menu key open the focused row's menu under it.
        var presented: [(menu: NSMenu, view: NSView)] = []
        controller.presentsMenu = { menu, _, view in presented.append((menu, view)) }
        window.sendEvent(try key(109, "\u{F70D}", [.shift, .function], in: window))
        window.sendEvent(try key(110, "", [], in: window))
        #expect(presented.count == 2)
        #expect(presented.first?.menu.items.map(\.title) == ["Reply", "Copy Message", "Select Message"])
        #expect(presented.first?.view === controller.collectionView.item(at: IndexPath(item: try messageRow(1, of: controller), section: 0))?.view)
    }

    // MARK: Bubbles

    @Test("Bubbles select Finder style: click, Command, Shift from an anchor; Command C, the menu, recycling, a drag")
    func bubbles() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        for index in 0..<60 {
            try await fixture.say("Message \(index), with a little more text to give it a line or two.",
                                  at: Double(index) * 400, byWorker: index % 2 == 1)
            if index == 57 {
                try await fixture.record(.toolActivity, subject: UUID(), at: Double(index) * 400 + 1,
                                         text: "→ read_log {}")
            }
        }
        let stage = await stage(fixture, pasteboard: pasteboard)
        defer { stage.window.close() }
        let controller = stage.controller
        let window     = stage.window
        func row(_ message: Int) throws -> Int {
            try #require(controller.rows.firstIndex { $0.item.copyText.hasPrefix("Message \(message),") })
        }
        func id(_ message: Int) throws -> UUID { try #require(controller.rows[try row(message)].item.messageID) }
        func at(_ message: Int) throws -> CGPoint { try point(inRow: try row(message), x: 10, of: controller) }

        try click(at: try at(56), in: window)
        #expect(controller.bubbleSelection == [try id(56)])
        #expect(controller.textSelection == nil, "a click never starts a text selection")
        #expect(window.firstResponder === controller.collectionView)

        // Shift from the anchor takes the messages between and skips the tool run; a second Shift replaces it.
        try click(at: try at(59), .shift, in: window)
        #expect(controller.bubbleSelection == Set([try id(56), try id(57), try id(58), try id(59)]))
        try click(at: try at(58), .shift, in: window)
        #expect(controller.bubbleSelection == Set([try id(56), try id(57), try id(58)]))

        window.sendEvent(try key(8, "c", .command, in: window))
        #expect(pasteboard.string(forType: .string) == (56...58).map {
            "Message \($0), with a little more text to give it a line or two."
        }.joined(separator: "\n\n"))
        let menu = try #require(try rightClick(at: try at(57), in: window))
        #expect(menu.items.map(\.title).prefix(2) == ["Reply", "Copy 3 Messages"])
        #expect(controller.bubbleSelection.count == 3)

        // Command adds or removes one, and the selected bubble says so to VoiceOver.
        try click(at: try at(57), .command, in: window)
        #expect(controller.bubbleSelection == Set([try id(56), try id(58)]))
        try click(at: try at(59), .command, in: window)
        #expect(controller.bubbleSelection == Set([try id(56), try id(58), try id(59)]))
        let selectedCell = try #require(controller.collectionView.item(at: IndexPath(item: try row(58), section: 0))
            as? TranscriptCell)
        #expect(selectedCell.rowView.isAccessibilitySelected())

        // Far enough up to page and recycle every cell, and back: the ids hold, the cells draw them.
        let chosen = controller.bubbleSelection
        controller.setVisibleTop(0)
        await controller.settle()
        controller.view.layoutSubtreeIfNeeded()
        controller.scrollToBottom()
        await controller.settle()
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.bubbleSelection == chosen)
        for path in controller.collectionView.indexPathsForVisibleItems() {
            let cell = try #require(controller.collectionView.item(at: path) as? TranscriptCell)
            let item = controller.rows[path.item].item
            #expect(cell.rowView.isBubbleSelected == (item.messageID.map(chosen.contains) ?? false))
        }

        // A drag selects text and clears the bubbles; Escape clears; Command A takes every loaded message.
        try drag(from: try at(55), to: try point(inRow: try row(55), x: 90, of: controller), in: window)
        #expect(controller.bubbleSelection.isEmpty)
        #expect(controller.textSelection?.isEmpty == false)
        try click(at: try at(55), in: window)
        #expect(controller.textSelection == nil)
        window.sendEvent(try key(53, "\u{1B}", [], in: window))
        #expect(controller.bubbleSelection.isEmpty)
        controller.collectionView.selectAll(nil)
        #expect(controller.bubbleSelection.count == controller.rows.count { $0.item.messageID != nil })
    }

    // MARK: Entrance

    @Test("A message arriving at the bottom plays its entrance, sampled on the layer; a paged row does not")
    func entrance() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        for index in 0..<(TranscriptWindow.pageSize + 20) {
            try await fixture.say("Message \(index), with a little more text to give it a line or two.",
                                  at: Double(index) * 400, byWorker: index % 2 == 1)
        }
        let stage = await stage(fixture, pasteboard: NSPasteboard(name: .init("mecum.tests.\(UUID())")))
        defer { stage.window.close() }
        let controller = stage.controller
        #expect(controller.isAtBottom)

        try await fixture.say("A reply that just arrived.", at: 100_000, byWorker: true)
        controller.refresh()
        await controller.settle()
        let index = controller.rows.count - 1
        let cell  = try #require(controller.collectionView.item(at: IndexPath(item: index, section: 0))
            as? TranscriptCell)
        let layer = try #require(cell.view.layer)
        #expect(layer.animation(forKey: "entrance") != nil)

        // Sampled while the window's display cycle runs: faded and lowered, then in place.
        var samples: [(opacity: Float, rise: CGFloat)] = []
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(20))
            guard let shown = layer.presentation() else { continue }
            samples.append((shown.opacity, shown.transform.m42))
        }
        print("entrance samples (opacity, translation y): \(samples)")
        #expect(samples.contains { $0.opacity > 0.01 && $0.opacity < 0.99 }, "a sample mid fade")
        #expect(samples.contains { $0.rise > 0.1 }, "a sample below its place, rising")
        try await Task.sleep(for: .milliseconds(250))
        #expect(layer.animation(forKey: "entrance") == nil)
        #expect(layer.presentation()?.opacity ?? 1 == 1)

        // The page loaded above the reader arrives without an entrance.
        controller.setVisibleTop(0)
        controller.loadOlder()
        await controller.settle()
        #expect(controller.lastUpdate?.inserted.isEmpty == false)
        let playing = controller.collectionView.visibleItems().filter { $0.view.layer?.animation(forKey: "entrance") != nil }
        #expect(playing.isEmpty)

        // Reduce Motion keeps the fade and drops the movement.
        cell.playEntrance(reducesMotion: true)
        let group = try #require(layer.animation(forKey: "entrance") as? CAAnimationGroup)
        #expect(group.animations?.compactMap { ($0 as? CABasicAnimation)?.keyPath } == ["opacity"])
    }

    // MARK: Indicator and inset

    @Test("Scrolled up, arrivals raise a counted pill above the inset; a click clears it; both insets keep rows clear")
    func indicatorAndInset() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        var waiting: MessageSnapshot?
        for index in 0..<40 {
            let message = try await fixture.say("Message \(index), with a little more text to give it a line or two.",
                                                at: Double(index) * 400, byWorker: index % 2 == 1,
                                                delivery: index == 38 ? .sentToBackend : .completed)
            if index == 38 { waiting = message }
        }
        let stage = await stage(fixture, pasteboard: NSPasteboard(name: .init("mecum.tests.\(UUID())")))
        defer { stage.window.close() }
        let controller = stage.controller

        // The inset keeps the last row clear of what floats over the bottom.
        controller.bottomInset = 90
        #expect(controller.isAtBottom)
        let clip = controller.collectionView.visibleRect
        let last = try #require(controller.frameMap()[controller.rows[controller.rows.count - 1].item.id])
        #expect(last.maxY <= clip.maxY - 90)
        #expect(controller.indicator.isHidden)

        // A change to a row already seen reads as New Activity.
        controller.setVisibleTop(600)
        #expect(!controller.isAtBottom)
        try await fixture.store.update(message: try #require(waiting?.id), delivery: .completed)
        controller.refresh()
        await controller.settle()
        #expect(controller.newActivity == .statusChanges)
        #expect(!controller.indicator.isHidden && controller.indicator.title == "New Activity")

        for index in 0..<3 {
            try await fixture.say("Arrived \(index).", at: 100_000 + Double(index), byWorker: true)
            controller.refresh()
            await controller.settle()
        }
        #expect(controller.newActivity == .messages)
        #expect(controller.indicator.title == "3 new messages")
        stage.window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.indicator.frame.minY >= 90, "the pill sits above the inset")

        controller.indicator.performClick(nil)
        await controller.settle()
        #expect(controller.indicator.isHidden)
        #expect(controller.newMessageCount == 0)
        #expect(controller.isAtBottom)

        // A header over the top: at the oldest end the first row clears it.
        controller.topInset = 70
        controller.setVisibleTop(0)
        let firstRow = try #require(controller.frameMap()[controller.rows[0].item.id])
        #expect(firstRow.minY >= controller.collectionView.visibleRect.minY + 70)
        #expect(controller.captureAnchor()?.itemID == controller.rows[0].item.id)
    }

    // MARK: Switching

    @Test("Back from a short conversation, a long one opened at its end has cells for the rows in view")
    func switchingConversations() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        for index in 0..<60 {
            try await fixture.say("Message \(index), with a little more text to give it a line or two.",
                                  at: Double(index) * 400, byWorker: index % 2 == 1)
        }
        let short = try await fixture.store.createConversation(participants: [fixture.workerID]).id
        try await fixture.store.appendMessage(to: short, author: nil, text: "One short message.",
                                              at: TranscriptFixture.at(0), delivery: .completed)
        let stage = await stage(fixture, pasteboard: NSPasteboard(name: .init("mecum.tests.\(UUID())")))
        defer { stage.window.close() }
        let controller = stage.controller

        for conversation in [short, fixture.conversation, short, fixture.conversation] {
            controller.open(conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                            readingAnchor: nil, readingOffset: 0)
            await controller.settle()
            let collectionView = controller.collectionView
            let frames = controller.frameMap()
            let inView = Set(controller.rows.indices.filter { index in
                frames[controller.rows[index].item.id]?.intersects(collectionView.visibleRect) ?? false
            })
            let drawn = Set(collectionView.visibleItems().compactMap { item in
                collectionView.indexPath(for: item).flatMap { path in
                    item.view.frame == frames[controller.rows[path.item].item.id] ? path.item : nil
                }
            })
            #expect(!inView.isEmpty)
            #expect(inView.isSubset(of: drawn), "rows in view without a cell: \(inView.subtracting(drawn).sorted())")
        }
    }

    // MARK: Replies

    @Test("Reply from the menu, Command R and VoiceOver quote the whole message, or the text selected in it")
    func replyQuotes() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let question   = try await fixture.say(
            "Where are the notes?",
            at: 0
        )
        let answer     = try await fixture.say(
            "The notes are in the release folder, beside the build log.",
            at      : 10,
            byWorker: true
        )
        let stage      = await stage(
            fixture,
            pasteboard: pasteboard
        )
        defer { stage.window.close() }
        let controller = stage.controller
        let window     = stage.window
        let answerRow  = try messageRow(
            1,
            of: controller
        )
        var quotes: [MessageQuote] = []
        controller.onReply = { quotes.append($0) }

        func at(
            _ row: Int,
            x    : CGFloat
        ) throws -> CGPoint {
            try point(
                inRow: row,
                x    : x,
                of   : controller
            )
        }

        // With nothing selected, the menu's Reply quotes the whole message, and says who wrote it.
        let whole = try #require(try rightClick(
            at: try at(answerRow, x: 10),
            in: window
        ))
        #expect(whole.items.first?.title == "Reply")
        whole.performActionForItem(at: 0)
        #expect(quotes.last == MessageQuote(
            messageID     : answer.id,
            authorWorkerID: fixture.workerID,
            text          : answer.text
        ))

        // A selection inside the message: the menu's Reply, opened inside it, quotes the selection.
        let id = controller.rows[answerRow].item.id
        controller.select(TranscriptSelection(
            anchor: .init(itemID: id, offset: 4),
            focus : .init(itemID: id, offset: 9)
        ))
        let part = try #require(try rightClick(
            at: try at(answerRow, x: 40),
            in: window
        ))
        #expect(part.items.map(\.title).prefix(2) == ["Copy", "Reply"])
        part.performActionForItem(at: 1)
        #expect(quotes.last?.text == "notes")
        #expect(quotes.last?.messageID == answer.id)

        // Command R on the focused message: the person's own, whole, with no author.
        try click(
            at: try at(try messageRow(0, of: controller), x: 10),
            in: window
        )
        #expect(window.firstResponder === controller.collectionView)
        window.sendEvent(try key(15, "r", .command, in: window))
        #expect(quotes.last == MessageQuote(
            messageID     : question.id,
            authorWorkerID: nil,
            text          : question.text
        ))

        // Command R after a drag inside the worker's message quotes what the drag selected.
        try drag(
            from: try at(answerRow, x: 0),
            to  : try at(answerRow, x: 70),
            in  : window
        )
        let selected = try #require(controller.textSelection?.span(in: controller.rows)?.text(in: controller.rows))
        window.sendEvent(try key(15, "r", .command, in: window))
        #expect(quotes.last?.text == selected.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(quotes.last?.text.isEmpty == false)
        #expect(quotes.last?.text != answer.text)

        // VoiceOver's Reply on the row.
        controller.select(nil)
        let cell  = try #require(controller.collectionView.item(at: IndexPath(item: answerRow, section: 0))
            as? TranscriptCell)
        let reply = try #require(cell.rowView.accessibilityCustomActions()?.first { $0.name == "Reply" })
        #expect(reply.handler?() == true)
        #expect(quotes.last?.text == answer.text)
        #expect(quotes.count == 5)
    }

    @Test("A quoted bubble is taller than the same bubble without its quote, and says what it replies to")
    func quotedBubbleGeometry() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let answer  = try await fixture.say(
            "Two bundles failed: capture and layout.",
            at      : 0,
            byWorker: true
        )
        try await fixture.say(
            "Same words.",
            at: 400
        )
        try await fixture.store.appendMessage(
            to      : fixture.conversation,
            text    : "Same words.",
            at      : TranscriptFixture.at(800),
            delivery: .completed,
            quote   : MessageQuote(
                messageID     : answer.id,
                authorWorkerID: fixture.workerID,
                text          : answer.text
            )
        )
        let stage      = await stage(
            fixture,
            pasteboard: NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        )
        defer { stage.window.close() }
        let controller = stage.controller
        let quotedRow  = try messageRow(
            2,
            of: controller
        )
        let plain      = controller.rows[try messageRow(1, of: controller)]
        let quoted     = controller.rows[quotedRow]
        let frames     = controller.frameMap()

        #expect(quoted.item.quote?.messageID == answer.id)
        #expect(plain.item.quote == nil)
        let quotedHeight = try #require(frames[quoted.item.id]?.height)
        let plainHeight  = try #require(frames[plain.item.id]?.height)
        #expect(quotedHeight > plainHeight)
        #expect(quoted.geometry.height == quotedHeight, "the layout places the height preparation measured")
        let block = try #require(quoted.geometry.quote)
        #expect(quoted.geometry.surface.contains(block))
        #expect(block.maxY < quoted.geometry.text.minY, "the quote sits above the message's own text")
        #expect(quoted.geometry.quoteName != nil, "a quote of the worker's message names the worker")
        #expect(quoted.text.string == "Same words.", "the quote is not part of the row's text")
        #expect(quoted.item.copyText == "Same words.")

        let cell  = try #require(controller.collectionView.item(at: IndexPath(item: quotedRow, section: 0))
            as? TranscriptCell)
        let label = try #require(cell.rowView.accessibilityLabel())
        #expect(label.hasPrefix("In reply to Atlas: Two bundles failed: capture and layout. You, "))
    }

    @Test("A click on a quote reveals its message, loading it from outside the window, and so do Right and Return")
    func quoteRevealsOriginal() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        var original: MessageSnapshot?
        for index in 0..<80 {
            let message = try await fixture.say(
                "Message \(index), with a little more text to give it a line or two.",
                at      : Double(index) * 400,
                byWorker: index % 2 == 1
            )
            if index == 1 { original = message }
        }
        let quoted = try #require(original)
        try await fixture.store.appendMessage(
            to      : fixture.conversation,
            text    : "About that one.",
            at      : TranscriptFixture.at(80 * 400),
            delivery: .completed,
            quote   : MessageQuote(
                messageID     : quoted.id,
                authorWorkerID: fixture.workerID,
                text          : quoted.text
            )
        )
        let stage      = await stage(
            fixture,
            pasteboard: NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        )
        defer { stage.window.close() }
        let controller = stage.controller
        let window     = stage.window
        let target     = TranscriptItem.ID.message(quoted.id)
        #expect(!controller.rows.contains { $0.item.id == target }, "the quoted message starts outside the window")

        func clickQuote() throws {
            let index = try #require(controller.rows.lastIndex { $0.item.quote != nil })
            let row   = controller.rows[index]
            let frame = try #require(controller.frameMap()[row.item.id])
            let block = try #require(row.geometry.quote)
            let point = CGPoint(
                x: frame.minX + block.midX,
                y: frame.minY + block.midY
            )
            try click(
                at: controller.collectionView.convert(point, to: nil),
                in: window
            )
        }
        func isRevealed() throws -> Bool {
            let index = try #require(controller.rows.firstIndex { $0.item.id == target })
            let frame = try #require(controller.frameMap()[target])
            return controller.collectionView.selectionIndexPaths.first?.item == index
                && abs(frame.minY - controller.visibleTop) < 1
        }

        try clickQuote()
        await controller.settle()
        #expect(try isRevealed())
        let index = try #require(controller.rows.firstIndex { $0.item.id == target })
        let cell  = try #require(controller.collectionView.item(at: IndexPath(item: index, section: 0))
            as? TranscriptCell)
        #expect(cell.rowView.flashAmount > 0, "the revealed bubble is tinted")
        try await Task.sleep(for: .milliseconds(900))
        #expect(cell.rowView.flashAmount == 0, "and the tint has faded")

        // From the keyboard: the quote is the reply row's first action.
        controller.scrollToBottom()
        await controller.settle()
        let reply = try #require(controller.rows.lastIndex { $0.item.quote != nil })
        controller.collectionView.selectionIndexPaths = [IndexPath(item: reply, section: 0)]
        window.makeFirstResponder(controller.collectionView)
        window.sendEvent(try key(124, "\u{F703}", [.function], in: window))
        window.sendEvent(try key(36, "\r", [], in: window))
        await controller.settle()
        #expect(try isRevealed())
    }
}

/// KeyboardHolder takes the keyboard, as the composer does, and nothing else.
private final class KeyboardHolder: NSView {
    override var acceptsFirstResponder: Bool { true }
}

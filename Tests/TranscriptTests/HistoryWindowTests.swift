//
//  HistoryWindowTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Transcript
@testable import Workspace

/// A long history kept fast (§12.5, §20.2): a bounded window that trims and
/// pages back, a distant message opened in one read, and a reader who is not
/// moved while four streams run. Small datasets; the 10,000 message one is
/// the benchmarks'.
@Suite("Transcript history: trimming, distant windows and simultaneous streams")
@MainActor
struct HistoryWindowTests {

    private func controller(
        _ source       : any ConversationWindowSource,
        _ conversation : UUID,
        pasteboard     : NSPasteboard = .general,
        height         : CGFloat = 500
    ) async -> TranscriptController {
        let controller = TranscriptController(source: source, pasteboard: pasteboard)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        controller.view.layoutSubtreeIfNeeded()
        controller.open(conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        return controller
    }

    /// Puts the reader a little inside the row at `index`, away from both ends.
    private func read(_ controller: TranscriptController, row index: Int) throws -> ScrollAnchor {
        let frame = try #require(controller.frameMap()[controller.rows[index].item.id])
        controller.setVisibleTop(frame.minY + 5)
        return try #require(controller.captureAnchor())
    }

    private func sequences(_ controller: TranscriptController, in store: WorkspaceStore) async throws -> [Int] {
        var result: [Int] = []
        for row in controller.rows {
            guard let id = row.item.messageID, let message = try await store.message(id) else { continue }
            result.append(message.sequence)
        }
        return result
    }

    @Test("Paging up drops the far end of the window, paging down reads it back, and the anchor stays")
    func windowTrimsAndPagesBack() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        for index in 0..<250 {
            try await fixture.say("Message \(index)", at: Double(index) * 400, byWorker: index % 2 == 1)
        }
        let spy        = SpyingSource(store: fixture.store)
        let controller = await controller(spy, fixture.conversation)
        #expect(try await sequences(controller, in: fixture.store) == Array(201...250))

        for expected in [151...250, 101...250, 51...200] {
            let anchor = try read(controller, row: 12)
            controller.loadOlder()
            await controller.settle()
            #expect(try await sequences(controller, in: fixture.store) == Array(expected))
            #expect(controller.captureAnchor() == anchor)
        }
        #expect(controller.rows.count == TranscriptWindow.messageLimit)
        #expect(!controller.isAtBottom)

        let lower  = try read(controller, row: controller.rows.count - 30)
        controller.loadNewer()
        await controller.settle()
        #expect(try await sequences(controller, in: fixture.store) == Array(101...250))
        #expect(controller.captureAnchor() == lower)

        let asked = await spy.messageRequests
        #expect(asked.allSatisfy { $0.before + $0.after <= TranscriptWindow.pageSize + 1 })
    }

    @Test("Revealing a distant message reads one window around it, not the pages between, and lands on it")
    func revealOpensOneWindow() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        var target: MessageSnapshot?
        for index in 0..<400 {
            let message = try await fixture.say("Message \(index), a line of text.", at: Double(index) * 400)
            if index == 60 { target = message }
        }
        let id         = try #require(target?.id)
        let spy        = SpyingSource(store: fixture.store)
        let controller = await controller(spy, fixture.conversation)
        let before     = await spy.messageRequests.count

        controller.reveal(message: id)
        await controller.settle()

        let asked = await spy.messageRequests.dropFirst(before)
        // One window around the message, and one row for the newest sequence below it.
        #expect(asked.count == 2)
        #expect(asked.reduce(0) { $0 + $1.before + $1.after } <= TranscriptWindow.pageSize + 2)
        #expect(try await sequences(controller, in: fixture.store) == Array(36...85))
        #expect(controller.captureAnchor() == ScrollAnchor(itemID: .message(id), offset: 0))
        #expect(controller.collectionView.selectionIndexPaths.first.map { controller.rows[$0.item].item.id }
            == .message(id))
        #expect(controller.reloadCount == 2)

        // Its end is not loaded: a message arriving there raises the indicator, and going back opens it.
        try await fixture.say("A new message below.", at: 401 * 400)
        controller.refresh()
        await controller.settle()
        #expect(controller.newActivity == .messages)
        controller.scrollToBottom()
        await controller.settle()
        #expect(try await sequences(controller, in: fixture.store).last == 401)
        #expect(controller.isAtBottom)
    }

    @Test("Four streams, two here and two in another conversation: the reader stays, keeps a code selection, all land")
    func fourStreams() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let store      = fixture.store
        let other      = try await store.createConversation(participants: [fixture.workerID]).id
        for index in 0..<40 {
            let text = index == 7
                ? "Here is the check:\n\n```swift\nlet passed = try await run(suite)\nprint(passed)\n```"
                : "Message \(index), with a little more text to give it a line or two."
            try await fixture.say(text, at: Double(index) * 400, byWorker: index % 2 == 1)
        }

        // Two turns stream in the open conversation and two in the other one.
        var streams: [(message: UUID, turn: UUID, conversation: UUID)] = []
        for (offset, conversation) in [fixture.conversation, fixture.conversation, other, other].enumerated() {
            let turn = UUID()
            let at   = TranscriptFixture.at(20_000 + Double(offset))
            try await store.append(NewEvent(workspaceID: TranscriptFixture.workspaceID, subjectID: turn,
                                            conversationID: conversation, workerID: fixture.workerID,
                                            timestamp: at, type: .executionStarted))
            let message = try await store.appendMessage(to: conversation, author: fixture.workerID, text: "",
                                                        at: at.addingTimeInterval(0.5), delivery: .responding)
            streams.append((message.id, turn, conversation))
        }
        let empty  = Dictionary(uniqueKeysWithValues: streams.map { ($0.message, "") })
        let source = GrowingSource(store: store, texts: empty)
        let here   = await controller(source, fixture.conversation, pasteboard: pasteboard)
        let there  = await controller(source, other)
        let window = TranscriptFixture.offscreenWindow(for: here.view, size: here.view.frame.size)
        defer { window.close() }
        there.view.isHidden = true

        // The reader goes back to the code and selects part of it.
        let code   = try #require(here.rows.firstIndex { $0.item.copyText.hasPrefix("Here is the check") })
        let anchor = try read(here, row: code)
        here.view.layoutSubtreeIfNeeded()
        let block  = try #require(here.rows[code].text.blocks.firstIndex { $0.isCompleteCode })
        let frame  = try #require(here.frameMap()[here.rows[code].item.id])
        let text   = here.rows[code].geometry.blockTexts[block]
        here.beginSelection(at: CGPoint(x: frame.minX + text.minX + 1, y: frame.minY + text.minY + 4), clickCount: 1)
        here.extendSelection(to: CGPoint(x: frame.minX + text.minX + 60, y: frame.minY + text.minY + 4))
        let selection = try #require(here.textSelection)
        here.copySelection()
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.hasPrefix("let"))
        #expect(!here.isAtBottom)

        for round in 0..<30 {
            for stream in streams {
                await source.append(round % 10 == 0 ? "\n\n```sh\nmake step\(round)\n```\n\n" : " token\(round)",
                                    to: stream.message)
            }
            here.refresh()
            there.refresh()
            try await Task.sleep(for: .milliseconds(5))
        }
        var endings: [UUID: TranscriptItem.ID] = [:]
        for stream in streams {
            try await store.update(message: stream.message, delivery: .completed)
            let ended = try await store.append(NewEvent(
                workspaceID: TranscriptFixture.workspaceID, subjectID: stream.turn,
                conversationID: stream.conversation, workerID: fixture.workerID,
                timestamp: TranscriptFixture.at(30_000), type: .executionCompleted
            ))
            endings[stream.message] = .event(ended.id)
        }
        here.refresh()
        there.refresh()
        await here.settle()
        await there.settle()

        #expect(here.captureAnchor() == anchor)
        #expect(here.textSelection == selection)
        here.copySelection()
        #expect(pasteboard.string(forType: .string) == copied)
        #expect(here.newActivity == .statusChanges)

        let texts = await source.texts
        for stream in streams {
            let shown = stream.conversation == fixture.conversation ? here : there
            let row   = shown.rows.first { $0.item.id == .message(stream.message) }
            #expect(row?.item.copyText == texts[stream.message])
            let ended = endings[stream.message]
            #expect(shown.rows.contains { $0.item.id == ended && $0.item.kind == .executionCompleted })
        }
    }
}

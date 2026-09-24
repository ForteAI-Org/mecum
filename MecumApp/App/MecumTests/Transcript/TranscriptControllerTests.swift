//
//  TranscriptControllerTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Mecum

/// The AppKit engine driven offscreen: no window is ordered in and no
/// permission is needed, so these run in the unit tier.
@Suite("Transcript controller: targeted updates and anchoring")
@MainActor
struct TranscriptControllerTests {

    private func opened(_ fixture: TranscriptFixture, messages: Int) async throws -> TranscriptController {
        for index in 0..<messages {
            try await fixture.say("Message \(index), with a little more text to give it a line or two.",
                                  at: Double(index) * 400, byWorker: index % 2 == 1,
                                  delivery: index == messages - 2 ? .sentToBackend : .completed)
        }
        let controller = TranscriptController(source: fixture.store)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance, readingAnchor: nil,
                        readingOffset: 0)
        await controller.settle()
        return controller
    }

    @Test("One changed row is one targeted update, and the collection view is not reloaded")
    func oneChangeOneUpdate() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let controller = try await opened(fixture, messages: 12)
        #expect(controller.reloadCount == 1)
        #expect(controller.isAtBottom)

        let question = try #require(controller.rows.last { $0.item.authorWorkerID == nil }?.item.messageID)
        try await fixture.store.update(message: question, delivery: .completed)
        controller.refresh()
        await controller.settle()

        #expect(controller.reloadCount == 1)
        #expect(controller.lastUpdate?.changed == [.message(question)])
        #expect(controller.lastUpdate?.inserted == [])
        #expect(controller.lastUpdate?.removed == [])
    }

    @Test("Loading an older page keeps the row being read where it was on screen")
    func olderPageKeepsAnchor() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let controller = try await opened(fixture, messages: 130)
        let messages   = { controller.rows.filter { $0.item.messageID != nil }.count }
        #expect(messages() == TranscriptWindow.pageSize)

        controller.setVisibleTop(900)
        let anchor = try #require(controller.captureAnchor())
        controller.loadOlder()
        await controller.settle()

        #expect(messages() == 2 * TranscriptWindow.pageSize)
        let top = try #require(anchor.visibleTop(in: controller.frameMap()))
        #expect(top > 900)
        #expect(controller.captureAnchor() == anchor)
    }

    @Test("Opening restores the remembered anchor and offset")
    func opensAtReadingPosition() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        var anchor: MessageSnapshot?
        for index in 0..<60 {
            let message = try await fixture.say("Message \(index)", at: Double(index) * 400)
            if index == 30 { anchor = message }
        }
        let id = try #require(anchor?.id)
        let controller = TranscriptController(source: fixture.store)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance, readingAnchor: id,
                        readingOffset: 12)
        await controller.settle()

        #expect(controller.captureAnchor() == ScrollAnchor(itemID: .message(id), offset: 12))
    }

    // MARK: Streaming

    /// A conversation whose reply streams through `GrowingSource`, opened on a
    /// controller with its own pipeline. Only a test that copies passes a pasteboard.
    private func streaming(_ fixture: TranscriptFixture, reply: String, pipeline: MarkdownContent,
                           pasteboard: NSPasteboard = .general)
        async throws -> (TranscriptController, GrowingSource, UUID) {
        try await fixture.say("Show me the build steps.", at: 0)
        let message = try await fixture.say("", at: 2, byWorker: true, delivery: .responding)
        let source  = GrowingSource(store: fixture.store, streaming: message.id, text: reply)
        let controller = TranscriptController(source: source, pipeline: pipeline, pasteboard: pasteboard)
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        return (controller, source, message.id)
    }

    @Test("A burst of deltas reaches the view in few updates, and the terminal update lands off screen")
    func burstIsGrouped() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let (controller, source, id) = try await streaming(fixture, reply: "Step", pipeline: MarkdownContent())
        let before = controller.viewUpdateCount

        for index in 0..<60 {
            await source.append(" \(index)")
            controller.refresh()
        }
        await controller.settle()
        #expect(controller.viewUpdateCount - before <= 3)
        let streamed = await source.text
        #expect(controller.rows.first { $0.item.id == .message(id) }?.item.copyText == streamed)

        // The reader looks elsewhere: the view is hidden, and the turn's end still applies.
        controller.view.isHidden = true
        await source.append(". Done.")
        try await fixture.record(.executionFailed, subject: UUID(), at: 5, text: "exit 1")
        controller.refresh()
        await controller.settle()
        #expect(controller.rows.last?.item.kind == .executionFailed(reason: "exit 1"))
        #expect(controller.rows.first { $0.item.id == .message(id) }?.item.copyText == streamed + ". Done.")
    }

    @Test("Completing a streamed fence prepares only the changed blocks and keeps the reader's selection")
    func selectionSurvivesCompletion() async throws {
        let fixture  = try await TranscriptFixture()
        defer { fixture.discard() }
        let pipeline = MarkdownContent()
        let (controller, source, id) = try await streaming(
            fixture, reply: "Build it in two steps.\n\n```sh\nmake", pipeline: pipeline
        )
        let index  = try #require(controller.rows.firstIndex { $0.item.id == .message(id) })
        let chosen = NSRange(location: 9, length: 12)
        controller.select(TranscriptSelection(anchor: .init(itemID: .message(id), offset: 9),
                                              focus : .init(itemID: .message(id), offset: 21)))
        #expect(controller.selectedRange(ofRow: index) == chosen)

        let spent = pipeline.preparedBlockCount
        await source.append(" test\n```\n\nThat is all.")
        controller.refresh()
        await controller.settle()

        let row = try #require(controller.rows.first { $0.item.id == .message(id) })
        #expect(row.text.blocks.map(\.kind) == [.text, .code(language: "sh", isComplete: true), .text])
        #expect(pipeline.preparedBlockCount - spent == 2)
        #expect(controller.textSelection?.anchor.itemID == .message(id))
        let rowIndex  = try #require(controller.rows.firstIndex { $0.item.id == .message(id) })
        let selection = try #require(controller.selectedRange(ofRow: rowIndex))
        #expect((row.text.string as NSString).substring(with: selection) == "in two steps")
    }

    @Test("Copy block is reachable from the keyboard: focus the reply, move to its Copy, press Return")
    func copyBlockFromKeyboard() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let (controller, _, _) = try await streaming(
            fixture, reply: "Run this:\n\n```sh\nmake test\n```", pipeline: MarkdownContent(), pasteboard: pasteboard
        )
        for code: UInt16 in [125, 125, 124, 36] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
            ))
            controller.collectionView.keyDown(with: event)
        }
        #expect(pasteboard.string(forType: .string) == "make test")
    }

    @Test("A wrapped code line continues under its own indentation, and Copy block returns the source exactly")
    func wrappedCodeHangs() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let long = "        let passed = try await launch(suite, attempt: attempt, retries: retries, timeout: 30)"
        let code = "func run() {\n\tif ready {\n\(long)\n\t}\n}"
        let (controller, _, id) = try await streaming(
            fixture, reply: "```swift\n\(code)\n```", pipeline: MarkdownContent(), pasteboard: pasteboard
        )
        controller.view.frame.size.width = 480
        controller.view.layoutSubtreeIfNeeded()
        await controller.settle()

        let index = try #require(controller.rows.firstIndex { $0.item.id == .message(id) })
        let cell  = try #require(controller.collectionView.item(at: IndexPath(item: index, section: 0))
            as? TranscriptCell)
        let (storage, manager, _) = try #require(cell.rowView.stacks.first ?? nil)
        let line = (storage.string as NSString).range(of: long)
        #expect(line.location != NSNotFound)

        // The x where a glyph sits inside its line fragment, as drawn.
        func x(ofCharacter character: Int) -> CGFloat {
            let glyph = manager.glyphIndexForCharacter(at: character)
            return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                + manager.location(forGlyphAt: glyph).x
        }
        let firstGlyph = manager.glyphIndexForCharacter(at: line.location)
        var firstLine  = NSRange()
        manager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: &firstLine)
        let continuation = manager.characterIndexForGlyph(at: NSMaxRange(firstLine))
        #expect(continuation < NSMaxRange(line), "the line must wrap at 480 points")

        let indentation = x(ofCharacter: line.location + 8)
        #expect(indentation > 0)
        #expect(x(ofCharacter: continuation) >= indentation)
        #expect(x(ofCharacter: line.location) == 0)

        controller.collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        for key: UInt16 in [124, 36] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key
            ))
            controller.collectionView.keyDown(with: event)
        }
        #expect(pasteboard.string(forType: .string).map { Array($0.utf8) } == Array(code.utf8))
    }
}

/// GrowingSource serves the store's windows with some messages' text taken
/// from buffers that grow, the way a streamed reply's does between flushes.
actor GrowingSource {

    let store: WorkspaceStore
    private(set) var texts: [UUID: String]

    init(store: WorkspaceStore, streaming: UUID, text: String) {
        self.init(store: store, texts: [streaming: text])
    }

    init(store: WorkspaceStore, texts: [UUID: String]) {
        self.store = store
        self.texts = texts
    }

    /// The streamed text, when one message streams.
    var text: String { texts.values.first ?? "" }

    /// Grows every stream by `delta`.
    func append(_ delta: String) {
        for id in texts.keys { texts[id, default: ""] += delta }
    }

    func append(_ delta: String, to id: UUID) { texts[id, default: ""] += delta }

    func messages(in conversation: UUID, around position: Int, before: Int, after: Int) async throws
        -> [MessageSnapshot] {
        try await store.messages(in: conversation, around: position, before: before, after: after).map(streamed)
    }

    func message(_ id: UUID) async throws -> MessageSnapshot? {
        try await store.message(id).map(streamed)
    }

    func events(inConversation conversation: UUID, from start: Date, before end: Date, limit: Int) async throws
        -> [RecordedEvent] {
        try await store.events(inConversation: conversation, from: start, before: end, limit: limit)
    }

    private func streamed(_ message: MessageSnapshot) -> MessageSnapshot {
        guard let text = texts[message.id] else { return message }
        return MessageSnapshot(Message(id: message.id, conversationID: message.conversationID,
                                       authorWorkerID: message.authorWorkerID, text: text,
                                       createdAt: message.createdAt, sequence: message.sequence,
                                       delivery: message.delivery))
    }
}

// The conformance sits apart because a nonisolated protocol on the declaration would make the actor nonisolated.
extension GrowingSource: ConversationWindowSource {}

//
//  CrossRowSelectionTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Transcript
@testable import Workspace

/// The selection in logical coordinates (§12.5), driven offscreen through the
/// controller's hit testing and keyboard, with a private pasteboard.
@Suite("Transcript selection across messages")
@MainActor
struct CrossRowSelectionTests {

    /// Fifty messages, one window at the oldest so nothing pages, with a tool
    /// run after the fourth and Markdown in every tenth, whose source differs
    /// from what is drawn.
    private func opened(_ fixture: TranscriptFixture, pasteboard: NSPasteboard) async throws
        -> (TranscriptController, NSWindow) {
        for index in 0..<50 {
            let text = index % 10 == 0
                ? "Message \(index) has **bold** words and `code` in it, and a little more text."
                : "Message \(index), with a little more text to give it a line or two."
            try await fixture.say(text, at: Double(index) * 400, byWorker: index % 2 == 1)
            if index == 3 {
                try await fixture.record(.executionStarted, subject: UUID(), at: Double(index) * 400 + 1)
                try await fixture.record(.toolActivity, subject: UUID(), at: Double(index) * 400 + 2,
                                         text: "→ read_log {}")
            }
        }
        let controller = TranscriptController(source: fixture.store, pasteboard: pasteboard)
        let window     = TranscriptFixture.offscreenWindow(for: controller.view, size: CGSize(width: 600, height: 400))
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        return (controller, window)
    }

    /// A point on the first line of the row's first block, `x` points in, in
    /// the collection view's coordinates.
    private func point(inRow index: Int, of controller: TranscriptController, x: CGFloat = 40) throws -> CGPoint {
        let row   = controller.rows[index]
        let frame = try #require(controller.frameMap()[row.item.id])
        let text  = row.geometry.blockTexts[0]
        return CGPoint(x: frame.minX + text.minX + x, y: frame.minY + text.minY + 4)
    }

    private func scroll(_ controller: TranscriptController, toRow index: Int) throws {
        let frame = try #require(controller.frameMap()[controller.rows[index].item.id])
        controller.setVisibleTop(frame.minY - 40)
        controller.view.layoutSubtreeIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
    }

    private func visible(_ controller: TranscriptController) -> Set<Int> {
        Set(controller.collectionView.indexPathsForVisibleItems().map(\.item))
    }

    private func cell(_ controller: TranscriptController, row index: Int) throws -> TranscriptCell {
        try #require(controller.collectionView.item(at: IndexPath(item: index, section: 0)) as? TranscriptCell)
    }

    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], characters: String = "") throws
        -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    @Test("A drag from one message to a distant one selects all between, across recycled rows, and copies the source")
    func dragAcrossRecycledRows() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let (controller, window) = try await opened(fixture, pasteboard: pasteboard)
        defer { window.close() }
        let rows       = controller.rows
        let start      = try #require(rows.firstIndex { $0.item.copyText.hasPrefix("Message 2,") })
        let end        = try #require(rows.firstIndex { $0.item.copyText.hasPrefix("Message 41,") })
        let toolRun    = try #require(rows.firstIndex { if case .toolRun = $0.item.kind { true } else { false } })
        #expect(start < toolRun && toolRun < end)

        try scroll(controller, toRow: start)
        controller.beginSelection(at: try point(inRow: start, of: controller), clickCount: 1)
        let startCell = try cell(controller, row: start)

        // The drag carries on while the rows it began on scroll away and are reused.
        var isReused = false
        for index in stride(from: start + 4, through: end, by: 4) {
            try scroll(controller, toRow: index)
            controller.extendSelection(to: try point(inRow: index, of: controller, x: 30))
            if let shown = controller.collectionView.indexPath(for: startCell), shown.item != start { isReused = true }
        }
        controller.extendSelection(to: try point(inRow: end, of: controller, x: 30))
        #expect(!visible(controller).contains(start))
        #expect(isReused, "the cell the drag began in shows another row by its end")

        let selection = try #require(controller.textSelection)
        #expect(selection.anchor.itemID == rows[start].item.id)
        #expect(selection.focus.itemID == rows[end].item.id)
        let head = selection.anchor.offset, tail = selection.focus.offset
        #expect(head > 0 && head < rows[start].length)
        #expect(tail > 0 && tail < rows[end].length)

        // Rows coming back from the recycler draw the logical selection.
        try scroll(controller, toRow: start)
        #expect(try cell(controller, row: start).rowView.selection
            == NSRange(location: head, length: rows[start].length - head))
        #expect(try cell(controller, row: start + 1).rowView.selection
            == NSRange(location: 0, length: rows[start + 1].length))
        #expect(try cell(controller, row: toolRun).rowView.selection == nil)

        controller.copySelection()
        let expected = [(rows[start].text.string as NSString).substring(from: head)]
            + rows[(start + 1)..<end].filter { $0.item.messageID != nil }.map(\.item.copyText)
            + [(rows[end].text.string as NSString).substring(to: tail)]
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied == expected.joined(separator: "\n\n"))
        #expect(copied.contains("Message 10 has **bold** words and `code` in it"))
        #expect(!copied.contains("read_log"))
    }

    @Test("Shift Command A selects the focused message, Shift arrows extend by row, Command A takes the loaded rows")
    func keyboardSelection() async throws {
        let fixture    = try await TranscriptFixture()
        defer { fixture.discard() }
        let pasteboard = NSPasteboard(name: .init("mecum.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        try await fixture.say("First question.", at: 0)
        try await fixture.say("Run this:\n\n```sh\nmake test\n```", at: 10, byWorker: true)
        try await fixture.record(.toolActivity, subject: UUID(), at: 11, text: "→ run {}")
        try await fixture.say("Second question.", at: 20)
        let controller = TranscriptController(source: fixture.store, pasteboard: pasteboard)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        let view = controller.collectionView

        view.keyDown(with: try key(125))
        view.keyDown(with: try key(0, [.command, .shift], characters: "a"))
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "First question.")

        view.keyDown(with: try key(125, .shift))
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "First question.\n\nRun this:\n\n```sh\nmake test\n```")

        // The next step skips the tool run, which a selection over rows does not take.
        view.keyDown(with: try key(125, .shift))
        view.copy(nil)
        #expect(pasteboard.string(forType: .string)?.hasSuffix("```\n\nSecond question.") == true)
        view.keyDown(with: try key(126, .shift))
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "First question.\n\nRun this:\n\n```sh\nmake test\n```")

        view.selectAll(nil)
        #expect(view.selectionIndexPaths.count <= 1)
        view.copy(nil)
        #expect(pasteboard.string(forType: .string)
            == "First question.\n\nRun this:\n\n```sh\nmake test\n```\n\nSecond question.")

        // Copy block: the reply focused, Right reaches its Copy, Return runs it.
        let reply = try #require(controller.rows.firstIndex { $0.item.authorWorkerID != nil })
        view.selectionIndexPaths = [IndexPath(item: reply, section: 0)]
        view.keyDown(with: try key(124))
        view.keyDown(with: try key(36))
        #expect(pasteboard.string(forType: .string) == "make test")
    }

    @Test("A selection survives an update to a row it spans, and clamps inwards when a spanned row goes")
    func selectionSurvivesAndClamps() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Show me the build steps.", at: 0)
        let streaming = try await fixture.say("Step", at: 2, byWorker: true, delivery: .responding)
        let source     = GrowingSource(store: fixture.store, streaming: streaming.id, text: "Step one")
        let controller = TranscriptController(source: source)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        let first  = try #require(controller.rows.first?.item.id)
        let chosen = TranscriptSelection(anchor: .init(itemID: first, offset: 5),
                                         focus : .init(itemID: .message(streaming.id), offset: 6))
        controller.select(chosen)

        await source.append(", then two, then three.")
        controller.refresh()
        await controller.settle()
        #expect(controller.textSelection == chosen)
        #expect(controller.rows.last?.item.copyText == "Step one, then two, then three.")

        // Rows gone: each end moves inwards to the nearest spanned row that stays.
        let rows  = controller.rows
        let (a, b) = (rows[0], rows[1])
        let spanning = TranscriptSelection(anchor: .init(itemID: a.item.id, offset: 3),
                                           focus : .init(itemID: b.item.id, offset: 4))
        #expect(spanning.kept(from: rows, in: [b])
            == TranscriptSelection(anchor: .init(itemID: b.item.id, offset: 0),
                                   focus : .init(itemID: b.item.id, offset: 4)))
        #expect(spanning.kept(from: rows, in: [a])
            == TranscriptSelection(anchor: .init(itemID: a.item.id, offset: 3),
                                   focus : .init(itemID: a.item.id, offset: a.length)))
        #expect(spanning.kept(from: rows, in: []) == nil)

        // An end past its row's new length is clamped, not trusted.
        let past = TranscriptSelection(anchor: .init(itemID: a.item.id, offset: 3),
                                       focus : .init(itemID: b.item.id, offset: 10_000))
        #expect(past.kept(from: rows, in: rows)?.focus.offset == b.length)
        controller.select(past)
        #expect(controller.selectedRange(ofRow: 1) == NSRange(location: 0, length: b.length))
    }
}

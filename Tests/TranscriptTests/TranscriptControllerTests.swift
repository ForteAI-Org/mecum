//
//  TranscriptControllerTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Transcript
import Workspace

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
        #expect(controller.rows.count == TranscriptWindow.pageSize)

        controller.setVisibleTop(900)
        let anchor = try #require(controller.captureAnchor())
        controller.loadOlder()
        await controller.settle()

        #expect(controller.rows.count == 2 * TranscriptWindow.pageSize)
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
}

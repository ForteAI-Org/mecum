//
//  MeasurementAndWindowTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import Transcript
import Workspace

@Suite("Measurement cache, window loading and scroll anchors")
struct MeasurementAndWindowTests {

    private static let item = TranscriptItem(
        id            : .message(UUID()),
        kind          : .workerReply(text: "A reply long enough to wrap at a narrow width, and then some.",
                                     isInterrupted: false),
        date          : TranscriptFixture.origin,
        authorWorkerID: UUID(),
        continuesGroup: false
    )

    @Test("The cache hits on the same content, width and style, and misses on another width or text size")
    func cacheKeys() async {
        let style  = TranscriptStyle(bodyPointSize: 14)
        let larger = TranscriptStyle(bodyPointSize: 20)
        let first  = await RowPreparation.prepare([Self.item], workerName: "Atlas", width: 480, style: style,
                                                  cache: LayoutMeasurementCache(), pipeline: PlainTextContent())
        #expect(first.measured.count == 1)

        var cache = LayoutMeasurementCache()
        cache.merge(first.measured)

        let again = await RowPreparation.prepare([Self.item], workerName: "Atlas", width: 480.2, style: style,
                                                 cache: cache, pipeline: PlainTextContent())
        #expect(again.measured.isEmpty)

        let wider = await RowPreparation.prepare([Self.item], workerName: "Atlas", width: 900, style: style,
                                                 cache: cache, pipeline: PlainTextContent())
        #expect(wider.measured.count == 1)

        let bigger = await RowPreparation.prepare([Self.item], workerName: "Atlas", width: 480, style: larger,
                                                  cache: cache, pipeline: PlainTextContent())
        #expect(bigger.measured.count == 1)
        #expect(bigger.rows[0].geometry.height > first.rows[0].geometry.height)
    }

    @Test("Opening and paging ask the store for bounded windows, never the whole history")
    func windowsAreBounded() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        for index in 0..<130 {
            try await fixture.say("Message \(index)", at: Double(index), byWorker: index % 2 == 1)
        }
        let spy = SpyingSource(store: fixture.store)

        let newest = try await TranscriptWindow.opening(fixture.conversation, around: nil, from: spy)
        #expect(newest.messages.count == TranscriptWindow.pageSize)
        #expect(newest.messages.last?.sequence == 130)
        #expect(!newest.isAtOldest)

        let older = try await newest.loadingOlder(from: spy)
        #expect(older.messages.count == 2 * TranscriptWindow.pageSize)
        #expect(older.messages.map(\.sequence) == Array(31...130))

        let asked = await spy.messageRequests
        #expect(!asked.isEmpty)
        #expect(asked.allSatisfy { $0.before + $0.after <= TranscriptWindow.pageSize + 1 })
    }

    @Test("A remembered anchor opens the window around it")
    func windowAroundAnchor() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        var anchor: MessageSnapshot?
        for index in 0..<200 {
            let message = try await fixture.say("Message \(index)", at: Double(index))
            if index == 99 { anchor = message }
        }
        let window = try await TranscriptWindow.opening(fixture.conversation, around: anchor?.id,
                                                        from: fixture.store)
        #expect(window.messages.contains { $0.id == anchor?.id })
        #expect(!window.isAtNewest && !window.isAtOldest)
        #expect(window.messages.count == TranscriptWindow.pageSize)
    }

    @Test("Rows added above keep the anchor row at the same distance from the viewport top")
    func anchorSurvivesPrepend() {
        let ids    = (0..<5).map { _ in TranscriptItem.ID.message(UUID()) }
        let before = ids.enumerated().map { (id: $1, frame: CGRect(x: 0, y: CGFloat($0) * 100, width: 400, height: 90)) }
        let anchor = ScrollAnchor.capture(frames: before, visibleTop: 230)
        #expect(anchor == ScrollAnchor(itemID: ids[2], offset: 30))

        // Three rows of 120 points arrive above.
        let after = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.frame.offsetBy(dx: 0, dy: 360)) })
        #expect(anchor?.visibleTop(in: after) == 590)
    }

    @Test("A reading position restores its anchor and its offset, clamped to the row")
    func readingPositionRestores() {
        let id       = TranscriptItem.ID.message(UUID())
        let position = ScrollAnchor(itemID: id, offset: 37.5)
        #expect(position.visibleTop(in: [id: CGRect(x: 0, y: 1000, width: 400, height: 80)]) == 1037.5)
        #expect(position.visibleTop(in: [id: CGRect(x: 0, y: 1000, width: 400, height: 20)]) == 1020)
        #expect(position.visibleTop(in: [:]) == nil)
    }
}

/// SpyingSource forwards to the store and remembers every window asked for.
actor SpyingSource: ConversationWindowSource {

    struct Request: Sendable { let position: Int; let before: Int; let after: Int }

    let store: WorkspaceStore
    private(set) var messageRequests: [Request] = []

    init(store: WorkspaceStore) { self.store = store }

    func messages(in conversation: UUID, around position: Int, before: Int, after: Int) async throws
        -> [MessageSnapshot] {
        messageRequests.append(Request(position: position, before: before, after: after))
        return try await store.messages(in: conversation, around: position, before: before, after: after)
    }

    func message(_ id: UUID) async throws -> MessageSnapshot? {
        try await store.message(id)
    }

    func events(inConversation conversation: UUID, from start: Date, before end: Date, limit: Int) async throws
        -> [RecordedEvent] {
        try await store.events(inConversation: conversation, from: start, before: end, limit: limit)
    }
}

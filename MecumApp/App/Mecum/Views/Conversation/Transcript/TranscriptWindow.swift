//
//  TranscriptWindow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// TranscriptWindow is the slice of one conversation the transcript holds:
/// consecutive messages by sequence, and the events stamped between the first
/// of them and the message after the last.
///
/// Every operation reads a bounded page through `ConversationWindowSource`
/// and returns a new window; a read that throws leaves the old one standing.
///
/// The window holds at most `messageLimit` messages. Loading a page at one
/// end drops messages past the limit from the other, which is the end away
/// from the reader, so memory stops growing however far they page (§20.2),
/// and paging back reads those messages again.
///
/// An event read is capped at `eventLimit`. A span with more keeps its latest
/// events and records where it was cut in `elidedBefore`, and the projection
/// puts a notice there, so no activity disappears without a row saying so.
nonisolated struct TranscriptWindow: Sendable, Equatable {

    static let pageSize          = 50
    static let defaultEventLimit = 2000
    static let messageLimit      = 3 * pageSize

    let conversationID: UUID
    let eventLimit    : Int
    private(set) var messages: [MessageSnapshot] = []
    private(set) var events  : [RecordedEvent]   = []

    /// The first kept event of every span whose read reached the cap.
    private(set) var elidedBefore: Set<UUID> = []

    /// No message below the first one.
    private(set) var isAtOldest = true

    /// No message above the last one, so new activity lands in this window.
    private(set) var isAtNewest = true

    /// The highest message sequence the store held at the window's last read
    /// of the conversation's newest end, which a window away from it compares
    /// against to tell a new message from a status change below.
    private(set) var newestSequence = 0

    init(conversationID: UUID, eventLimit: Int = TranscriptWindow.defaultEventLimit) {
        self.conversationID = conversationID
        self.eventLimit     = max(1, eventLimit)
    }

    /// The window around `anchor` when the store still has it, else the newest page.
    static func opening(
        _ conversationID: UUID,
        around anchor   : UUID?,
        from source     : any ConversationWindowSource,
        eventLimit      : Int = TranscriptWindow.defaultEventLimit
    ) async throws -> TranscriptWindow {
        var window = TranscriptWindow(conversationID: conversationID, eventLimit: eventLimit)
        let half   = pageSize / 2

        if let anchor, let found = try await source.message(anchor), found.conversationID == conversationID {
            let page = try await source.messages(in: conversationID, around: found.sequence,
                                                 before: half, after: half + 1)
            let hasMore = page.filter { $0.sequence >= found.sequence }.count > half
            window.messages   = hasMore ? Array(page.dropLast()) : page
            window.isAtNewest = !hasMore
            window.isAtOldest = (window.messages.first?.sequence ?? 1) <= 1
            if hasMore {
                // The first message past the window bounds its events; the next page owns the rest.
                window.events = try await window.readEvents(from: source, start: window.lowerEventBound,
                                                            end: page[page.count - 1].createdAt)
            }
        } else {
            window.messages   = try await source.messages(in: conversationID, around: Int.max,
                                                          before: pageSize, after: 0)
            window.isAtNewest = true
            window.isAtOldest = (window.messages.first?.sequence ?? 1) <= 1
        }
        if window.isAtNewest {
            window.events = try await window.readEvents(from: source, start: window.lowerEventBound,
                                                        end: .distantFuture)
            window.newestSequence = window.messages.last?.sequence ?? 0
        } else {
            window.newestSequence = try await window.readNewestSequence(from: source)
        }
        return window
    }

    /// One page older, prepended, and the newest messages past
    /// `messageLimit` dropped. Nothing is read when the window is at the oldest.
    func loadingOlder(from source: any ConversationWindowSource) async throws -> TranscriptWindow {
        guard !isAtOldest, let first = messages.first else { return self }
        let page   = try await source.messages(in: conversationID, around: first.sequence,
                                               before: Self.pageSize, after: 0)
        var window = self
        window.messages   = page + messages
        window.isAtOldest = (page.first?.sequence ?? 1) <= 1
        let earlier = try await window.readEvents(from: source, start: window.lowerEventBound,
                                                  end: first.createdAt)
        window.events = earlier + events
        window.dropNewest(keeping: Self.messageLimit)
        return window
    }

    /// One page newer, appended, and the oldest messages past `messageLimit`
    /// dropped. Nothing is read when the window is at the newest.
    func loadingNewer(from source: any ConversationWindowSource) async throws -> TranscriptWindow {
        guard !isAtNewest, let last = messages.last else { return self }
        let page    = try await source.messages(in: conversationID, around: last.sequence + 1,
                                                before: 0, after: Self.pageSize + 1)
        let hasMore = page.count > Self.pageSize
        guard let start = page.first?.createdAt else { return self }
        var window = self
        window.messages   = messages + (hasMore ? Array(page.dropLast()) : page)
        window.isAtNewest = !hasMore
        // The old window's events stopped at the first message past it, which is this page's first.
        let end    = hasMore ? page[page.count - 1].createdAt : .distantFuture
        let later  = try await window.readEvents(from: source, start: start, end: end)
        window.events = events + later
        if !hasMore { window.newestSequence = max(newestSequence, window.messages.last?.sequence ?? 0) }
        window.dropOldest(keeping: Self.messageLimit)
        return window
    }

    /// The live tail read again: from the last message the person wrote, whose
    /// delivery is what moves during a turn, or from the earliest reply still
    /// responding when that is older, so replies streaming side by side all
    /// grow, to the newest.
    ///
    /// Away from the newest, only the newest sequence is read, so the reader
    /// can be told whether a message arrived below; its end is not what they see.
    func refreshingTail(from source: any ConversationWindowSource) async throws -> TranscriptWindow {
        guard isAtNewest else {
            var window = self
            window.newestSequence = max(newestSequence, try await readNewestSequence(from: source))
            return window
        }
        let streaming = messages.first { !$0.isFromPerson && $0.delivery == .responding }
        let moving    = [streaming, messages.last(where: \.isFromPerson)].compactMap { $0 }
        guard let tail = moving.min(by: { $0.sequence < $1.sequence }) ?? messages.last else {
            return try await Self.opening(conversationID, around: nil, from: source, eventLimit: eventLimit)
        }
        let page = try await source.messages(in: conversationID, around: tail.sequence,
                                             before: 0, after: eventLimit)
        var window = self
        window.messages     = messages.filter { $0.sequence < tail.sequence } + page
        window.elidedBefore = elidedBefore.filter { id in
            events.contains { $0.id == id && $0.timestamp < tail.createdAt }
        }
        let fresh = try await window.readEvents(from: source, start: tail.createdAt, end: .distantFuture)
        window.events = events.filter { $0.timestamp < tail.createdAt } + fresh
        window.newestSequence = max(newestSequence, window.messages.last?.sequence ?? 0)
        return window
    }

    /// Drops messages from the newest end until `limit` are left, with the
    /// events that belonged to them. The first dropped message bounds what stays.
    private mutating func dropNewest(keeping limit: Int) {
        guard messages.count > limit else { return }
        let bound  = messages[limit].createdAt
        messages   = Array(messages.prefix(limit))
        events     = events.filter { $0.timestamp < bound }
        isAtNewest = false
        keepElisions()
    }

    /// Drops messages from the oldest end until `limit` are left, with the
    /// events that belonged to them: those stamped before the first kept message.
    private mutating func dropOldest(keeping limit: Int) {
        guard messages.count > limit else { return }
        messages   = Array(messages.suffix(limit))
        let bound  = messages[0].createdAt
        events     = events.filter { $0.timestamp >= bound }
        isAtOldest = false
        keepElisions()
    }

    private mutating func keepElisions() {
        let kept = Set(events.map(\.id))
        elidedBefore = elidedBefore.filter(kept.contains)
    }

    private func readNewestSequence(from source: any ConversationWindowSource) async throws -> Int {
        try await source.messages(in: conversationID, around: Int.max, before: 1, after: 0).last?.sequence ?? 0
    }

    /// Reads one span's events. One more than the cap is asked for, so a span
    /// that exactly fills it is not mistaken for one that was cut.
    private mutating func readEvents(
        from source: any ConversationWindowSource,
        start      : Date,
        end        : Date
    ) async throws -> [RecordedEvent] {
        let read = try await source.events(inConversation: conversationID, from: start, before: end,
                                           limit: eventLimit + 1)
        guard read.count > eventLimit else { return read }
        let kept = Array(read.suffix(eventLimit))
        elidedBefore.insert(kept[0].id)
        return kept
    }

    /// Events before the first message belong to this window only when no
    /// older page exists to own them.
    private var lowerEventBound: Date {
        isAtOldest || messages.isEmpty ? .distantPast : messages[0].createdAt
    }
}

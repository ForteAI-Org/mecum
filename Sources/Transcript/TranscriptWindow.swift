//
//  TranscriptWindow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Workspace

/// TranscriptWindow is the slice of one conversation the transcript holds:
/// consecutive messages by sequence, and the events stamped between the first
/// of them and the message after the last.
///
/// Every operation reads a bounded page through `ConversationWindowSource`
/// and returns a new window; a read that throws leaves the old one standing.
///
/// An event read is capped at `eventLimit`. A span with more keeps its latest
/// events and records where it was cut in `elidedBefore`, and the projection
/// puts a notice there, so no activity disappears without a row saying so.
public struct TranscriptWindow: Sendable, Equatable {

    public static let pageSize          = 50
    public static let defaultEventLimit = 2000

    public let conversationID: UUID
    public let eventLimit    : Int
    public private(set) var messages: [MessageSnapshot] = []
    public private(set) var events  : [RecordedEvent]   = []

    /// The first kept event of every span whose read reached the cap.
    public private(set) var elidedBefore: Set<UUID> = []

    /// No message below the first one.
    public private(set) var isAtOldest = true

    /// No message above the last one, so new activity lands in this window.
    public private(set) var isAtNewest = true

    public init(conversationID: UUID, eventLimit: Int = TranscriptWindow.defaultEventLimit) {
        self.conversationID = conversationID
        self.eventLimit     = max(1, eventLimit)
    }

    /// The window around `anchor` when the store still has it, else the newest page.
    public static func opening(
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
        }
        return window
    }

    /// One page older, prepended. Nothing is read when the window is at the oldest.
    public func loadingOlder(from source: any ConversationWindowSource) async throws -> TranscriptWindow {
        guard !isAtOldest, let first = messages.first else { return self }
        let page   = try await source.messages(in: conversationID, around: first.sequence,
                                               before: Self.pageSize, after: 0)
        var window = self
        // ponytail: the window only grows as the reader pages up; drop far pages when the
        // 10,000 message benchmarks of ticket 2.4 show the memory matters.
        window.messages   = page + messages
        window.isAtOldest = (page.first?.sequence ?? 1) <= 1
        let earlier = try await window.readEvents(from: source, start: window.lowerEventBound,
                                                  end: first.createdAt)
        window.events = earlier + events
        return window
    }

    /// The live tail read again: from the last message the person wrote, whose
    /// delivery is what moves during a turn, to the newest. A window away from
    /// the newest is returned unchanged; its end is not what the reader sees.
    public func refreshingTail(from source: any ConversationWindowSource) async throws -> TranscriptWindow {
        guard isAtNewest else { return self }
        guard let tail = messages.last(where: \.isFromPerson) ?? messages.last else {
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
        return window
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

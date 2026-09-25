//
//  ConversationProjection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// ConversationProjection turns what the store holds for a window of one
/// conversation into ordered transcript rows.
///
/// It is a pure function of its input: no store, no clock, no AppKit. It runs
/// off the main thread, and the same messages, events, expanded lines, instant
/// and calendar always give the same rows in the same order.
///
/// The merged order. Messages keep their `sequence` order and events keep
/// their `localOrder` order; neither is ever reordered. The two runs are then
/// merged as in the merge step of a merge sort: the next row is the message
/// when its `createdAt` is at or before the next event's `timestamp`, and the
/// event otherwise. A tie goes to the message, and a clock that stepped back
/// can misplace an event between two messages but never reorders a stream.
///
/// A turn's rows. An execution's start and completion draw nothing. Its tool
/// records fold into one line identified by its first event, so a line that
/// grows keeps its identity. The line opens the worker's part of the turn: it
/// sits above the turn's first reply block, or where the turn ended when it
/// replied nothing, and a failed or stopped turn adds its card after its last
/// row. While the newest execution runs, a thinking bubble sits at the end where
/// its next reply will land, unless a reply block is still streaming, and the
/// running turn's line sits above its first reply block, else above the bubble.
/// Both are the same place, so a line never moves when its turn ends.
///
/// Days. Every day with a message gets a separator above its first message,
/// the day changing at 00:00 in `calendar`'s time zone. A compaction or a fresh
/// context is a separator where it happened. Grouping is decided in the final
/// order, so a separator or a tool line starts a new group.
nonisolated enum ConversationProjection {

    /// Rows closer together than this, by one author, share a header.
    static let groupingInterval: TimeInterval = 300

    /// Projects `messages`, in sequence order, and `events`, in local order.
    /// Events of a type the transcript does not use are skipped.
    ///
    /// `elidedBefore` names the events a capped read was cut at. The first
    /// used event at or after each gets an `activityNotShown` row before it.
    ///
    /// `now` decides whether a saved message has waited long enough to be
    /// marked unsent (`DeliveryBadge.unsentGrace`) and what a day separator
    /// says; `calendar` decides where a day starts and how it is written.
    /// `isAtNewest` is false for a window that stops short of the newest
    /// message, whose last turn may have ended past it: no bubble is shown there.
    static func items(
        messages      : [MessageSnapshot],
        events        : [RecordedEvent],
        expanded      : Set<TranscriptItem.ID>,
        opensToolSteps: Bool = false,
        elidedBefore  : Set<UUID> = [],
        now           : Date,
        calendar      : Calendar = .autoupdatingCurrent,
        isAtNewest    : Bool = true
    ) -> [TranscriptItem] {

        var merge = Merge()
        var messageIndex = 0
        var eventIndex   = 0
        let shown        = events.filter(isShown)
        let notices      = noticePositions(events, elidedBefore: elidedBefore)

        while messageIndex < messages.count || eventIndex < shown.count {
            let takesMessage: Bool
            if messageIndex == messages.count {
                takesMessage = false
            } else if eventIndex == shown.count {
                takesMessage = true
            } else {
                takesMessage = messages[messageIndex].createdAt <= shown[eventIndex].timestamp
            }

            if takesMessage {
                merge.add(messages[messageIndex], now: now)
                messageIndex += 1
            } else {
                let event = shown[eventIndex]
                eventIndex += 1
                if notices.contains(event.id) {
                    merge.rows.append(TranscriptItem(id: .notice(event.id), kind: .activityNotShown,
                                                     date: event.timestamp, authorWorkerID: event.workerID,
                                                     continuesGroup: false))
                }
                merge.add(event)
            }
        }
        let ordered = merge.finish(expanded: expanded, opensToolSteps: opensToolSteps, showsThinking: isAtNewest)
        return grouped(dated(ordered, now: now, calendar: calendar))
    }

    /// True for the event types the projection reads.
    static func isShown(_ event: RecordedEvent) -> Bool {
        switch event.type {
        case .toolActivity, .executionStarted, .executionCompleted, .executionFailed, .executionCancelled,
             .contextCompacted, .contextReset:
            true
        default:
            false
        }
    }

    /// The first used event at or after each cut, which the notice goes before.
    private static func noticePositions(_ events: [RecordedEvent], elidedBefore: Set<UUID>) -> Set<UUID> {
        guard !elidedBefore.isEmpty else { return [] }
        var positions: Set<UUID> = []
        var isPending = false
        for event in events {
            if elidedBefore.contains(event.id) { isPending = true }
            if isPending, isShown(event) {
                positions.insert(event.id)
                isPending = false
            }
        }
        return positions
    }

    // MARK: Days and groups

    /// `rows` with a separator above the first message of every day.
    private static func dated(_ rows: [TranscriptItem], now: Date, calendar: Calendar) -> [TranscriptItem] {
        var result : [TranscriptItem] = []
        var lastDay: Date?
        result.reserveCapacity(rows.count + 4)
        for row in rows {
            if row.messageID != nil {
                let day = calendar.startOfDay(for: row.date)
                if day != lastDay {
                    let label = TranscriptWording.day(row.date, now: now, calendar: calendar)
                    result.append(TranscriptItem(id: .day(day), kind: .daySeparator(label: label), date: day,
                                                 authorWorkerID: nil, continuesGroup: false))
                    lastDay = day
                }
            }
            result.append(row)
        }
        return result
    }

    /// Each row's grouping in the final order. A message or a thinking bubble
    /// continues a bubble by its author a little earlier. A tool line continues
    /// nothing: it opens its worker's part of a turn, so the reply under it starts
    /// a group of its own, with its header. A bubble that no bubble below
    /// continues ends its group and carries the tail.
    private static func grouped(_ rows: [TranscriptItem]) -> [TranscriptItem] {
        var result: [TranscriptItem] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            var continues = false
            if let previous = result.last, isBubble(previous), previous.authorWorkerID == row.authorWorkerID {
                switch row.kind {
                case .personMessage, .workerReply, .thinking:
                    continues = row.date.timeIntervalSince(previous.date) < groupingInterval
                default:
                    continues = false
                }
            }
            result.append(row.continuesGroup == continues ? row : row.with(continuesGroup: continues))
        }
        for index in result.indices where isBubble(result[index]) {
            let next = index + 1 < result.count ? result[index + 1] : nil
            result[index].endsGroup = !(next.map { isBubble($0) && $0.continuesGroup } ?? false)
        }
        return result
    }

    private static func isBubble(_ row: TranscriptItem) -> Bool {
        switch row.kind {
        case .personMessage, .workerReply, .thinking: true
        default:                                      false
        }
    }

    // MARK: Merging

    /// Merge is the state of one pass over the merged order: the rows so far,
    /// each execution's tool line, and the turn still open.
    private struct Merge {

        /// A turn's tool records, and the row it goes before once placed.
        struct ToolLine {
            let id    : TranscriptItem.ID
            let date  : Date
            let worker: UUID?
            var lines : [String]
            var ending: TranscriptItem.TurnEnding?

            /// The row index the line goes before once its turn ended, `rows.count` after every row.
            var anchor: Int?
        }

        var rows: [TranscriptItem] = []

        private var lines    : [UUID: ToolLine] = [:]
        private var lineOrder: [UUID] = []

        /// The latest started execution with no terminal event yet, and its reply blocks so far.
        private var openTurn: (event: RecordedEvent, replies: Int)?

        /// The current answer's first and last reply blocks, since the last start or ending.
        private var firstReplyIndex: Int?
        private var lastReplyIndex : Int?
        private var isLastReplyStreaming = false

        mutating func add(_ message: MessageSnapshot, now: Date) {
            let badge = DeliveryBadge(message.delivery, savedAt: message.createdAt, now: now)
            let kind: TranscriptItem.Kind = message.isFromPerson
                ? .personMessage(text: message.text, delivery: message.delivery, badge: badge)
                : .workerReply(text: message.text, isInterrupted: false)
            if !message.isFromPerson {
                firstReplyIndex      = firstReplyIndex ?? rows.count
                lastReplyIndex       = rows.count
                isLastReplyStreaming = message.delivery == .responding
                openTurn?.replies   += 1
            }
            rows.append(TranscriptItem(id: .message(message.id), kind: kind, date: message.createdAt,
                                       authorWorkerID: message.authorWorkerID, continuesGroup: false))
        }

        mutating func add(_ event: RecordedEvent) {
            let text = event.payload.map { String(decoding: $0, as: UTF8.self) } ?? ""
            switch event.type {
            case .toolActivity:
                if lines[event.subjectID] == nil {
                    lineOrder.append(event.subjectID)
                    lines[event.subjectID] = ToolLine(id: .toolRun(event.id), date: event.timestamp,
                                                      worker: event.workerID, lines: [])
                }
                lines[event.subjectID]?.lines.append(text)

            case .executionStarted:
                openTurn        = (event, 0)
                firstReplyIndex = nil
                lastReplyIndex  = nil

            case .executionCompleted:
                end(event, as: .completed)

            case .executionFailed:
                markInterrupted()
                end(event, as: .failed)
                rows.append(card(event, .executionFailed(reason: text)))

            case .executionCancelled:
                markInterrupted()
                end(event, as: .stopped)
                rows.append(card(event, .executionInterrupted(note: text)))

            case .contextCompacted:
                let trigger = event.payloadVersion == ContextCompaction.payloadVersion
                    ? event.payload.flatMap(ContextCompaction.decoded)?.trigger
                    : nil
                rows.append(separator(event, trigger == .automatic ? .compactedAutomatically : .compacted))

            case .contextReset:
                rows.append(separator(event, .freshStart))

            default:
                break
            }
        }

        /// The rows with each tool line in place: an ended turn's before its
        /// anchor, the running turn's above its first reply block or else above
        /// the thinking bubble, and a line with no turn in the window at the end.
        mutating func finish(expanded: Set<TranscriptItem.ID>, opensToolSteps: Bool, showsThinking: Bool)
            -> [TranscriptItem] {
            // Where the running turn's line goes is where it stays once the turn ends: see `end`.
            let running = firstReplyIndex ?? rows.count
            if showsThinking, let open = openTurn, let worker = open.event.workerID,
               !(lastReplyIndex != nil && isLastReplyStreaming) {
                rows.append(TranscriptItem(id: .thinking(execution: open.event.subjectID, replies: open.replies),
                                           kind: .thinking, date: open.event.timestamp, authorWorkerID: worker,
                                           continuesGroup: false))
            }
            var before: [Int: [TranscriptItem]] = [:]
            var tail  : [TranscriptItem] = []
            for subject in lineOrder {
                guard let line = lines[subject] else { continue }
                let row = TranscriptItem(
                    id            : line.id,
                    // `expanded` holds the lines toggled against the default.
                    kind          : .toolRun(lines: line.lines, isExpanded: opensToolSteps != expanded.contains(line.id),
                                             ending: line.ending),
                    date          : line.date,
                    authorWorkerID: line.worker,
                    continuesGroup: false
                )
                if let anchor = line.anchor ?? (subject == openTurn?.event.subjectID ? running : nil) {
                    before[anchor, default: []].append(row)
                } else {
                    tail.append(row)
                }
            }
            guard !before.isEmpty || !tail.isEmpty else { return rows }
            var ordered: [TranscriptItem] = []
            ordered.reserveCapacity(rows.count + lineOrder.count)
            for (index, row) in rows.enumerated() {
                ordered += before[index] ?? []
                ordered.append(row)
            }
            return ordered + (before[rows.count] ?? []) + tail
        }

        /// Records how the turn ended on its tool line, and puts the line above
        /// the answer's first reply block, or here when it replied nothing.
        private mutating func end(_ event: RecordedEvent, as ending: TranscriptItem.TurnEnding) {
            if lines[event.subjectID] != nil {
                lines[event.subjectID]?.ending = ending
                lines[event.subjectID]?.anchor = firstReplyIndex ?? rows.count
            }
            if openTurn?.event.subjectID == event.subjectID { openTurn = nil }
            firstReplyIndex = nil
            lastReplyIndex  = nil
        }

        /// Marks the answer's last reply block as interrupted, when it has one.
        private mutating func markInterrupted() {
            guard let index = lastReplyIndex, case .workerReply(let text, _) = rows[index].kind else { return }
            rows[index] = rows[index].with(kind: .workerReply(text: text, isInterrupted: true))
        }

        private func card(_ event: RecordedEvent, _ kind: TranscriptItem.Kind) -> TranscriptItem {
            TranscriptItem(id: .event(event.id), kind: kind, date: event.timestamp, authorWorkerID: event.workerID,
                           continuesGroup: false)
        }

        /// A context separator speaks for no one, as a day's does.
        private func separator(_ event: RecordedEvent, _ change: TranscriptItem.ContextChange) -> TranscriptItem {
            TranscriptItem(id: .event(event.id), kind: .contextSeparator(change), date: event.timestamp,
                           authorWorkerID: nil, continuesGroup: false)
        }
    }
}

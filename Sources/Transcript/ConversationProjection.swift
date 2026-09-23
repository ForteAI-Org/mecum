//
//  ConversationProjection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Workspace

/// ConversationProjection turns what the store holds for a window of one
/// conversation into ordered transcript rows.
///
/// It is a pure function of its input: no store, no clock, no AppKit. It runs
/// off the main thread, and the same messages, events and expanded runs always
/// give the same rows in the same order.
///
/// The merged order. Messages keep their `sequence` order and events keep
/// their `localOrder` order; neither is ever reordered. The two runs are then
/// merged as in the merge step of a merge sort: the next row is the message
/// when its `createdAt` is at or before the next event's `timestamp`, and the
/// event otherwise. The clock therefore decides only where an event falls
/// between two messages, a tie goes to the message, and a clock that stepped
/// back can misplace an event between two messages but never reorders a stream.
///
/// Aggregation. Consecutive `toolActivity` events with nothing between them
/// fold into one `toolRun` row identified by its first event, so a run that
/// grows keeps its identity. Expanding a run changes that row's kind and
/// nothing else, so no other row moves in the order.
public enum ConversationProjection {

    /// Rows closer together than this, by one author, share a header.
    public static let groupingInterval: TimeInterval = 300

    /// Projects `messages`, in sequence order, and `events`, in local order.
    /// Events of a type the transcript does not show are skipped.
    ///
    /// `elidedBefore` names the events a capped read was cut at. The first
    /// shown event at or after each gets an `activityNotShown` row before it.
    ///
    /// `now` decides only whether a saved message has waited long enough to
    /// be marked unsent (`DeliveryBadge.unsentGrace`). It is passed in, so the
    /// same input at the same instant always gives the same rows.
    public static func items(
        messages    : [MessageSnapshot],
        events      : [RecordedEvent],
        expanded    : Set<TranscriptItem.ID>,
        elidedBefore: Set<UUID> = [],
        now         : Date
    ) -> [TranscriptItem] {

        var rows          : [TranscriptItem] = []
        var runStart      : Int?
        var lastReplyIndex: Int?
        var runsByTurn    : [UUID: [Int]] = [:]
        var messageIndex  = 0
        var eventIndex    = 0
        let shown         = events.filter(isShown)
        let notices       = noticePositions(events, elidedBefore: elidedBefore)

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
                let message = messages[messageIndex]
                messageIndex += 1
                runStart = nil
                if !message.isFromPerson { lastReplyIndex = rows.count }
                rows.append(row(for: message, after: rows.last, now: now))
                continue
            }

            let event = shown[eventIndex]
            eventIndex += 1
            if notices.contains(event.id) {
                runStart = nil
                rows.append(TranscriptItem(id: .notice(event.id), kind: .activityNotShown, date: event.timestamp,
                                           authorWorkerID: event.workerID, continuesGroup: false))
            }
            let text = event.payload.map { String(decoding: $0, as: UTF8.self) } ?? ""

            switch event.type {
            case .toolActivity:
                if let start = runStart, case .toolRun(let lines, _, _) = rows[start].kind {
                    rows[start] = TranscriptItem(
                        id            : rows[start].id,
                        kind          : .toolRun(lines: lines + [text],
                                                 isExpanded: expanded.contains(rows[start].id), ending: nil),
                        date          : rows[start].date,
                        authorWorkerID: rows[start].authorWorkerID,
                        continuesGroup: false
                    )
                } else {
                    let id = TranscriptItem.ID.toolRun(event.id)
                    runStart = rows.count
                    runsByTurn[event.subjectID, default: []].append(rows.count)
                    rows.append(TranscriptItem(
                        id            : id,
                        kind          : .toolRun(lines: [text], isExpanded: expanded.contains(id), ending: nil),
                        date          : event.timestamp,
                        authorWorkerID: event.workerID,
                        continuesGroup: false
                    ))
                }
                continue

            case .executionStarted:
                lastReplyIndex = nil
                rows.append(boundary(event, .executionStarted))

            case .executionCompleted:
                end(runsByTurn[event.subjectID] ?? [], in: &rows, as: .completed)
                rows.append(boundary(event, .executionCompleted))

            case .executionFailed:
                markInterrupted(&rows, at: lastReplyIndex)
                end(runsByTurn[event.subjectID] ?? [], in: &rows, as: .failed)
                rows.append(boundary(event, .executionFailed(reason: text)))

            case .executionCancelled:
                markInterrupted(&rows, at: lastReplyIndex)
                end(runsByTurn[event.subjectID] ?? [], in: &rows, as: .stopped)
                rows.append(boundary(event, .executionInterrupted(note: text)))

            default:
                break
            }
            runStart = nil
            if event.type.isTerminal { lastReplyIndex = nil }
        }
        return rows
    }

    /// The first shown event at or after each cut, which the notice goes before.
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

    /// True for the event types the transcript draws.
    static func isShown(_ event: RecordedEvent) -> Bool {
        switch event.type {
        case .toolActivity, .executionStarted, .executionCompleted, .executionFailed, .executionCancelled:
            true
        default:
            false
        }
    }

    private static func row(for message: MessageSnapshot, after previous: TranscriptItem?, now: Date)
        -> TranscriptItem {
        let badge = DeliveryBadge(message.delivery, savedAt: message.createdAt, now: now)
        let kind: TranscriptItem.Kind = message.isFromPerson
            ? .personMessage(text: message.text, delivery: message.delivery, badge: badge)
            : .workerReply(text: message.text, isInterrupted: false)

        var continues = false
        if let previous, previous.messageID != nil, previous.authorWorkerID == message.authorWorkerID {
            continues = message.createdAt.timeIntervalSince(previous.date) < groupingInterval
        }
        return TranscriptItem(
            id            : .message(message.id),
            kind          : kind,
            date          : message.createdAt,
            authorWorkerID: message.authorWorkerID,
            continuesGroup: continues
        )
    }

    private static func boundary(_ event: RecordedEvent, _ kind: TranscriptItem.Kind) -> TranscriptItem {
        TranscriptItem(
            id            : .event(event.id),
            kind          : kind,
            date          : event.timestamp,
            authorWorkerID: event.workerID,
            continuesGroup: false
        )
    }

    /// Records how the turn ended on each of its tool runs, so a call left
    /// without a result is no longer called running.
    private static func end(_ runs: [Int], in rows: inout [TranscriptItem], as ending: TranscriptItem.TurnEnding) {
        for index in runs {
            guard case .toolRun(let lines, let isExpanded, _) = rows[index].kind else { continue }
            let run = rows[index]
            rows[index] = TranscriptItem(
                id            : run.id,
                kind          : .toolRun(lines: lines, isExpanded: isExpanded, ending: ending),
                date          : run.date,
                authorWorkerID: run.authorWorkerID,
                continuesGroup: run.continuesGroup
            )
        }
    }

    /// Marks the answer's last reply block as interrupted, when it has one.
    private static func markInterrupted(_ rows: inout [TranscriptItem], at index: Int?) {
        guard let index, case .workerReply(let text, _) = rows[index].kind else { return }
        let reply = rows[index]
        rows[index] = TranscriptItem(
            id            : reply.id,
            kind          : .workerReply(text: text, isInterrupted: true),
            date          : reply.date,
            authorWorkerID: reply.authorWorkerID,
            continuesGroup: reply.continuesGroup
        )
    }
}

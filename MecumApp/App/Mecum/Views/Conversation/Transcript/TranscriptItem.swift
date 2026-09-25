//
//  TranscriptItem.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// TranscriptItem is one row of the transcript as `ConversationProjection`
/// produces it: a value, with an identity that survives every later update.
///
/// The kinds are distinct on purpose (§11.2). A person's message, a worker's
/// reply, the bubble of a worker still thinking, a turn's tool line, a day
/// separator and a failure are drawn differently and none of them borrows
/// another's shape.
nonisolated struct TranscriptItem: Sendable, Hashable, Identifiable {

    /// Stable across updates. A message is its message id, a failure or stop
    /// card is its event id, and a turn's tool line is its first event, which
    /// a line only ever grows after.
    enum ID: Sendable, Hashable {
        case message(UUID)
        case event(UUID)
        case toolRun(UUID)

        /// The notice placed before the event the window's read was cut at.
        case notice(UUID)

        /// The thinking bubble of a running execution after `replies` of its
        /// reply blocks. A new block takes the bubble's place, and a new id follows it.
        case thinking(execution: UUID, replies: Int)

        /// The separator above a day's first message: that day's start.
        case day(Date)
    }

    /// How the turn a row belongs to ended.
    enum TurnEnding: Sendable, Hashable {
        case completed
        case stopped
        case failed
    }

    enum Kind: Sendable, Hashable {

        /// What the person wrote, with how far it got and the badge that
        /// decided, when it went wrong.
        case personMessage(text: String, delivery: MessageDelivery, badge: DeliveryBadge?)

        /// A reply block. `isInterrupted` marks the last block of an answer
        /// that failed or was stopped: what arrived stays, marked (§11.5).
        case workerReply(text: String, isInterrupted: Bool)

        /// A turn's tool records folded into one line above its answer.
        /// Collapsed, it says what was done; expanded, each step. `ending` is
        /// nil while the turn runs.
        case toolRun(lines: [String], isExpanded: Bool, ending: TurnEnding?)

        /// A running turn's worker, before its next reply block. Never stored:
        /// derived from an execution that started and has no terminal event.
        case thinking

        /// The day the messages below it were sent, as the reader's calendar names it.
        case daySeparator(label: String)

        case executionFailed(reason: String)
        case executionInterrupted(note: String)

        /// The window's event read reached its cap: activity older than the
        /// next row, in the same span, exists and is not shown.
        case activityNotShown
    }

    let id  : ID
    let kind: Kind
    let date: Date

    /// The worker the row speaks for, or nil for the person.
    let authorWorkerID: UUID?

    /// True when the row above is a message by the same author, a little
    /// earlier: the name and mascot are drawn once for the group, and the
    /// accessibility label still carries both. A tool line never sets it, and
    /// the reply under one keeps its header.
    let continuesGroup: Bool

    /// True for the last bubble of a group, the one that carries the tail: no
    /// bubble below it continues its group. A tool line or a separator below ends it.
    var endsGroup = false

    /// The message id when this row is a message, which is what a reading
    /// position can anchor on.
    var messageID: UUID? {
        if case .message(let id) = id { id } else { nil }
    }

    /// The text a copy of the whole row gives.
    var copyText: String {
        switch kind {
        case .personMessage(let text, _, _), .workerReply(let text, _): text
        case .toolRun(let lines, _, _):                                  lines.joined(separator: "\n")
        case .daySeparator(let label):                                label
        case .executionFailed(let reason):                            reason
        case .executionInterrupted(let note):                         note
        case .activityNotShown:                                       TranscriptWording.activityNotShown
        case .thinking:                                               ""
        }
    }

    /// The same row with another kind or grouping, and the same identity.
    func with(kind: Kind? = nil, continuesGroup: Bool? = nil) -> TranscriptItem {
        TranscriptItem(
            id            : id,
            kind          : kind ?? self.kind,
            date          : date,
            authorWorkerID: authorWorkerID,
            continuesGroup: continuesGroup ?? self.continuesGroup,
            endsGroup     : endsGroup
        )
    }
}

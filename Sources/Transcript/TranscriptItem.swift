//
//  TranscriptItem.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Workspace

/// TranscriptItem is one row of the transcript as `ConversationProjection`
/// produces it: a value, with an identity that survives every later update.
///
/// The kinds are distinct on purpose (§11.2). A person's message, a worker's
/// reply, a run of tool activity, an execution divider and a failure are drawn
/// differently and none of them borrows another's bubble.
public struct TranscriptItem: Sendable, Hashable, Identifiable {

    /// Stable across updates. A message is its message id, an execution
    /// boundary is its event id, and a run of tool activity is its first
    /// event, which a run only ever grows after.
    public enum ID: Sendable, Hashable {
        case message(UUID)
        case event(UUID)
        case toolRun(UUID)

        /// The notice placed before the event the window's read was cut at.
        case notice(UUID)
    }

    /// How the turn a row belongs to ended.
    public enum TurnEnding: Sendable, Hashable {
        case completed
        case stopped
        case failed
    }

    public enum Kind: Sendable, Hashable {

        /// What the person wrote, with how far it got and the badge that
        /// decided, when it went wrong.
        case personMessage(text: String, delivery: MessageDelivery, badge: DeliveryBadge?)

        /// A reply block. `isInterrupted` marks the last block of an answer
        /// that failed or was stopped: what arrived stays, marked (§11.5).
        case workerReply(text: String, isInterrupted: Bool)

        /// Consecutive tool records folded into one row. Collapsed, it shows
        /// the counts; expanded, each line. `ending` is nil while the turn runs.
        case toolRun(lines: [String], isExpanded: Bool, ending: TurnEnding?)

        case executionStarted
        case executionCompleted
        case executionFailed(reason: String)
        case executionInterrupted(note: String)

        /// The window's event read reached its cap: activity older than the
        /// next row, in the same span, exists and is not shown.
        case activityNotShown
    }

    public let id  : ID
    public let kind: Kind
    public let date: Date

    /// The worker the row speaks for, or nil for the person.
    public let authorWorkerID: UUID?

    /// True when the row above is a message by the same author, a little
    /// earlier: the name and mascot are drawn once for the group, and the
    /// accessibility label still carries both.
    public let continuesGroup: Bool

    /// The message id when this row is a message, which is what a reading
    /// position can anchor on.
    public var messageID: UUID? {
        if case .message(let id) = id { id } else { nil }
    }

    /// The text a copy of the whole row gives.
    public var copyText: String {
        switch kind {
        case .personMessage(let text, _, _), .workerReply(let text, _): text
        case .toolRun(let lines, _, _):                                  lines.joined(separator: "\n")
        case .executionFailed(let reason):                            reason
        case .executionInterrupted(let note):                         note
        case .activityNotShown:                                       TranscriptWording.activityNotShown
        case .executionStarted, .executionCompleted:                  ""
        }
    }
}

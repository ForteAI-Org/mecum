//
//  EventType.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// EventType is the vocabulary of the operational record.
///
/// It covers the transitions Increment 1 produces. Types for tasks, handoffs
/// and artifacts arrive with the increments that produce them.
///
/// The store keeps an event's type as its raw value, a string column. A value
/// this build does not know, written by a newer build or by another branch on
/// the same store, reads back as `unknown` with that string rather than
/// failing the read, and writes back unchanged. A build released before this
/// rule fails on such a row, and nothing here can change that.
nonisolated enum EventType: Sendable, Hashable {

    case workerCreated
    case workerConfigured
    case workerArchived
    case conversationOpened
    case messageRecorded
    case messageDeliveryChanged
    case executionStarted
    case executionCompleted
    case executionFailed
    case executionCancelled

    /// One line of a turn's tool use, as the agent's tools recorded it. The
    /// payload is that line as UTF-8. Replies are messages, never this.
    case toolActivity

    /// The agent child process a turn started, so a launch after a crash can
    /// end it (§18.4). The payload is its identity as the agent host encodes
    /// it; the store does not read it.
    case agentProcessStarted

    /// What one turn cost and how full it left the model's context, once per
    /// turn that reported it. The payload is a `TurnUsage` as JSON, at
    /// `TurnUsage.payloadVersion`; a reader skips a row at another version.
    case turnUsage

    /// The conversation's model context was compacted, by the person or by
    /// Mecum at its context budget. The payload is a `ContextCompaction` as JSON, at
    /// `ContextCompaction.payloadVersion`; its subject is the conversation.
    case contextCompacted

    /// The conversation's model context started again with nothing from
    /// before it; the messages stay. No payload; its subject is the conversation.
    case contextReset

    /// A type this build does not know, with the raw value it was stored as.
    ///
    /// Readers skip it. It is never terminal here: whether the row ended its
    /// subject is its `deduplicationKey`'s to say, which the store still
    /// honours. Decoding never produces it for a value listed above.
    case unknown(String)

    /// True when the type ends a subject's work.
    ///
    /// A terminal transition is the one a repeated network result would apply
    /// twice, so it is keyed on its subject rather than on the delivery: see
    /// `NewEvent.deduplicationKey`.
    var isTerminal: Bool {
        switch self {
        case .executionCompleted, .executionFailed, .executionCancelled: true
        case .workerCreated, .workerConfigured, .workerArchived, .conversationOpened,
             .messageRecorded, .messageDeliveryChanged, .executionStarted, .toolActivity,
             .agentProcessStarted, .turnUsage, .contextCompacted, .contextReset, .unknown: false
        }
    }

    /// Every type this build knows, which is what decoding matches against.
    static let known: [EventType] = [
        .workerCreated, .workerConfigured, .workerArchived, .conversationOpened,
        .messageRecorded, .messageDeliveryChanged, .executionStarted, .executionCompleted, .executionFailed,
        .executionCancelled, .toolActivity, .agentProcessStarted, .turnUsage, .contextCompacted, .contextReset,
    ]
}

// Codable comes from the standard library's `RawRepresentable` default, which this initializer never fails.
nonisolated extension EventType: RawRepresentable, Codable {

    init(rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    var rawValue: String {
        switch self {
        case .workerCreated:          "workerCreated"
        case .workerConfigured:       "workerConfigured"
        case .workerArchived:         "workerArchived"
        case .conversationOpened:     "conversationOpened"
        case .messageRecorded:        "messageRecorded"
        case .messageDeliveryChanged: "messageDeliveryChanged"
        case .executionStarted:       "executionStarted"
        case .executionCompleted:     "executionCompleted"
        case .executionFailed:        "executionFailed"
        case .executionCancelled:     "executionCancelled"
        case .toolActivity:           "toolActivity"
        case .agentProcessStarted:    "agentProcessStarted"
        case .turnUsage:              "turnUsage"
        case .contextCompacted:       "contextCompacted"
        case .contextReset:           "contextReset"
        case .unknown(let value):     value
        }
    }
}

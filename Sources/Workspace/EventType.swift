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
public enum EventType: String, Codable, Sendable, CaseIterable {

    case workerCreated
    case workerConfigured
    case workerManagerChanged
    case workerArchived
    case conversationOpened
    case messageRecorded
    case messageDeliveryChanged
    case executionStarted
    case executionCompleted
    case executionFailed
    case executionCancelled

    /// True when the type ends a subject's work.
    ///
    /// A terminal transition is the one a repeated network result would apply
    /// twice, so it is keyed on its subject rather than on the delivery: see
    /// `NewEvent.deduplicationKey`.
    public var isTerminal: Bool {
        switch self {
        case .executionCompleted, .executionFailed, .executionCancelled: true
        case .workerCreated, .workerConfigured, .workerManagerChanged, .workerArchived,
             .conversationOpened, .messageRecorded, .messageDeliveryChanged, .executionStarted: false
        }
    }
}

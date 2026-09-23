//
//  TurnSummary.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import ModelTransports
import Workspace

/// TurnSummary is a worker's current or last turn as the inspector shows it
/// (§14.2): when it started, how it stands, and the model and effort it ran with.
///
/// The model and the effort come from the execution's frozen `selection`,
/// never from the worker's current profile, so editing the profile afterwards
/// does not rewrite which model produced a past answer.
public struct TurnSummary: Sendable, Hashable {

    public enum State: Sendable, Hashable {
        case running
        case completed
        case failed(reason: String)
        case stopped

        /// No terminal event and nothing running, such as a turn the app quit in.
        case unfinished
    }

    public let executionID: UUID
    public let startedAt  : Date
    public let selection  : ModelSelection
    public let state      : State

    /// `events` are the execution's own, in any order; the first terminal one
    /// decides the state. `isRunning` counts only while none has arrived.
    public init(execution: ExecutionSnapshot, events: [RecordedEvent], isRunning: Bool) {
        executionID = execution.id
        startedAt   = execution.startedAt
        selection   = execution.selection

        let ending = events.filter { $0.type.isTerminal }.min { $0.localOrder < $1.localOrder }
        switch ending?.type {
        case .executionCompleted?: state = .completed
        case .executionCancelled?: state = .stopped
        case .executionFailed?:
            state = .failed(reason: ending?.payload.map { String(decoding: $0, as: UTF8.self) } ?? "")
        default:
            state = isRunning ? .running : .unfinished
        }
    }

    /// Reads the worker's most recent execution and its events. Nil before the
    /// worker's first turn; a failed read throws as the store threw it.
    public static func latest(
        of worker: UUID,
        in store : WorkspaceStore,
        isRunning: Bool
    ) async throws -> TurnSummary? {
        guard let execution = try await store.latestExecution(of: worker) else { return nil }
        let events = try await store.events(matching: EventQuery(scope: .subject(execution.id)))
        return TurnSummary(execution: execution, events: events, isRunning: isRunning)
    }

    /// The model, then the effort when the model takes one, in the provider's words.
    public var modelLine: String { selection.line }

    /// A few words for the state.
    public var stateTitle: String {
        switch state {
        case .running:    "Running"
        case .completed:  "Completed"
        case .failed:     "Failed"
        case .stopped:    "Stopped"
        case .unfinished: "Ended without a recorded outcome"
        }
    }

    /// True for the states that mean something went wrong, which are the only
    /// ones the inspector marks.
    public var isTrouble: Bool {
        switch state {
        case .failed, .unfinished          : true
        case .running, .completed, .stopped: false
        }
    }
}

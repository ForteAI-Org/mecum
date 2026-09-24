//
//  WorkerTurnRecorder.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ChatCore
import CLIProviders
import Foundation
import ModelTransports

/// WorkerTurnRecorder writes one agent turn into the workspace (§11.5).
///
/// It starts the execution, which freezes the configuration the turn runs
/// with, records `executionStarted` and moves the person's message to sent.
/// Then it runs the agent once and writes what it reports in order: each reply
/// block as a message authored by the worker, and each tool record as a
/// `toolActivity` event, so a tool row is never a reply (§11.2). A block the
/// worker writes just before a tool call says what it is about to do rather
/// than answering, so it goes on the tool line as a note
/// (`ToolStep.noteRecord`). Which of the two a block is shows only in what
/// comes next, so each waits for the next event: a tool record makes it a
/// note, anything else a reply. A provider session it reports is stored on
/// the conversation with that provider, and the next turn on the same
/// provider is handed it to resume, across relaunches.
///
/// The turn ends with exactly one terminal event: `executionCompleted`,
/// `executionFailed` carrying the reason, or `executionCancelled` carrying the
/// interruption note. A failed or stopped message is marked interrupted, and
/// what arrived before stays. Nothing here runs the agent a second time.
///
/// The agent child's identity is recorded as `agentProcessStarted`, so that a
/// turn a crash cut short can be ended, and its child stopped, at the next
/// launch (`endTurnsLeftUnfinished`).
@MainActor
final class WorkerTurnRecorder {

    /// How a turn ended.
    enum Ending: Sendable, Equatable {
        case completed
        case failed(reason: String)
        case cancelled
    }

    /// The note a stopped turn leaves, word for word what `mecum chat` writes.
    static let interruptedNote = "Interrupted. Inspect the current app state before continuing."

    /// The reason a turn that an earlier launch left without an ending fails with.
    static let closedDuringTurnReason = "Mecum closed during this turn, so it did not finish and was "
        + "not run again. Inspect the current app state before continuing."

    /// What `endTurnsLeftUnfinished` did: the executions it ended and the pids
    /// of the agent children it stopped.
    struct Recovery: Sendable, Equatable {
        let endedExecutions : [UUID]
        let stoppedProcesses: [Int32]
    }

    /// Ends every turn an earlier launch left without an ending, then stops
    /// each one's agent child when it is provably the child that turn spawned
    /// and it outlived the app (§18.4). Call it before any turn starts.
    ///
    /// The ending is `WorkspaceStore.endExecutionsLeftUnfinished` with
    /// `closedDuringTurnReason`: the message reads interrupted, the replies
    /// stay, and nothing is run again. A second launch finds nothing to do.
    /// Throws the first store read or payload decoding that failed, after the
    /// turns are ended.
    @discardableResult
    static func endTurnsLeftUnfinished(in store: WorkspaceStore, workspaceID: UUID) async throws -> Recovery {
        let ended = try await store.endExecutionsLeftUnfinished(reason: closedDuringTurnReason, workspace: workspaceID)
        var stopped: [Int32] = []
        for execution in ended {
            for event in try await store.events(matching: EventQuery(scope: .subject(execution)))
            where event.type == .agentProcessStarted {
                guard let payload = event.payload else { continue }
                let identity = try JSONDecoder().decode(ChildProcessIdentity.self, from: payload)
                if identity.endIfOrphaned() { stopped.append(identity.pid) }
            }
        }
        return Recovery(endedExecutions: ended, stoppedProcesses: stopped)
    }

    private let store         : WorkspaceStore
    private let workspaceID   : UUID
    private let workerID      : UUID
    private let conversationID: UUID
    private let messageID     : UUID
    private let onRecorded    : @MainActor () async -> Void

    /// `messageID` is the person's message the turn answers. `onRecorded` is
    /// called after every write, on the main actor, so a reader can refresh.
    init(
        store         : WorkspaceStore,
        workspaceID   : UUID,
        workerID      : UUID,
        conversationID: UUID,
        messageID     : UUID,
        onRecorded    : @escaping @MainActor () async -> Void
    ) {
        self.store          = store
        self.workspaceID    = workspaceID
        self.workerID       = workerID
        self.conversationID = conversationID
        self.messageID      = messageID
        self.onRecorded     = onRecorded
    }

    /// The text a tool, failure or cancellation event carries, or nil for any
    /// other event.
    static func text(of event: RecordedEvent) -> String? {
        switch event.type {
        case .toolActivity, .executionFailed, .executionCancelled:
            event.payload.map { String(decoding: $0, as: UTF8.self) }
        default:
            nil
        }
    }

    /// Runs `agent` once with the execution's frozen selection and records it.
    ///
    /// `agent` receives the session to resume: the one stored on the
    /// conversation when it belongs to the frozen selection's provider, else nil.
    ///
    /// Throws before `agent` runs when the execution cannot be started, which
    /// leaves the message as it was. After that it always attempts the
    /// terminal event, and throws the first write that failed, if any.
    func run(
        _ agent: (ModelSelection, String?, @escaping @MainActor (WorkerAgentEvent) -> Void) async throws -> Void
    ) async throws -> Ending {
        let stored    = try await store.conversation(conversationID)
        let execution = try await store.startExecution(worker: workerID, conversation: conversationID)
        let provider  = execution.selection.provider
        let resumed   = stored?.resumableSession(for: provider)
        try await append(.executionStarted, subject: execution.id)
        try await store.update(message: messageID, delivery: .sentToBackend)
        await onRecorded()

        let (events, continuation) = AsyncStream.makeStream(of: WorkerAgentEvent.self)
        let writer = Task { @MainActor in
            var state = WriteState(session: resumed)
            for await event in events {
                do { try await write(event, execution: execution.id, provider: provider, state: &state) }
                catch { state.firstFailure = state.firstFailure ?? error }
            }
            // A block still waiting when the agent stopped was its last word: a reply.
            do { try await reply(&state) }
            catch { state.firstFailure = state.firstFailure ?? error }
            return state
        }

        let thrown: (any Error)?
        do {
            try await agent(execution.selection, resumed) { continuation.yield($0) }
            thrown = nil
        } catch {
            thrown = error
        }
        continuation.finish()
        let state = await writer.value

        let ending: Ending
        switch thrown {
        case is CancellationError:  ending = .cancelled
        case .some(let error):      ending = .failed(reason: state.reportedFailure ?? error.localizedDescription)
        case .none:                 ending = state.reportedFailure.map { .failed(reason: $0) } ?? .completed
        }
        try await finish(ending, execution: execution.id)
        if let failure = state.firstFailure { throw failure }
        return ending
    }

    // MARK: Writing

    private struct WriteState {
        var hasReply       = false
        var reportedFailure: String?
        var firstFailure   : (any Error)?

        /// The worker's last block, waiting to learn whether it introduces a tool call or answers.
        var held: String?

        /// The session the store holds for this provider, so a repeated id writes nothing.
        var session: String?
    }

    private func write(
        _ event  : WorkerAgentEvent,
        execution: UUID,
        provider : ModelProvider,
        state    : inout WriteState
    ) async throws {
        switch event {
        case .provider(.assistant(let text)):
            // A block after a block: the first one answered.
            try await reply(&state)
            state.held = text
            guard !state.hasReply else { return }

            state.hasReply = true
            try await store.update(message: messageID, delivery: .responding)
        case .provider(.failure(let reason)):
            try await reply(&state)
            // Kept for the one terminal event; the provider also throws it at the end.
            state.reportedFailure = reason
        case .tool(let text):
            if let note = state.held {
                state.held = nil
                try await append(.toolActivity, subject: execution, text: ToolStep.noteRecord(note))
            }
            try await append(.toolActivity, subject: execution, text: text)
        case .processStarted(let identity):
            let encoded = try JSONEncoder().encode(identity)
            try await append(.agentProcessStarted, subject: execution, text: String(decoding: encoded, as: UTF8.self))
            return
        case .provider(.session(let id)):
            guard id != state.session else { return }
            try await store.update(conversation: conversationID, .providerSession(provider: provider, id: id))
            state.session = id
            return
        case .provider(.completed):
            try await reply(&state)
        case .provider(.activity):
            return
        }
        await onRecorded()
    }

    /// Writes the waiting block as a reply, when one is waiting.
    private func reply(_ state: inout WriteState) async throws {
        guard let text = state.held else { return }

        state.held = nil
        try await store.appendMessage(to: conversationID, author: workerID, text: text, delivery: .completed)
    }

    private func finish(_ ending: Ending, execution: UUID) async throws {
        switch ending {
        case .completed:
            try await append(.executionCompleted, subject: execution)
            try await store.update(message: messageID, delivery: .completed)
        case .failed(let reason):
            try await append(.executionFailed, subject: execution, text: reason)
            try await store.update(message: messageID, delivery: .interrupted)
        case .cancelled:
            try await append(.executionCancelled, subject: execution, text: Self.interruptedNote)
            try await store.update(message: messageID, delivery: .interrupted)
        }
        await onRecorded()
    }

    private func append(_ type: EventType, subject: UUID, text: String? = nil) async throws {
        try await store.append(NewEvent(
            workspaceID   : workspaceID,
            subjectID     : subject,
            conversationID: conversationID,
            workerID      : workerID,
            type          : type,
            payload       : text.map { Data($0.utf8) },
            correlationID : messageID
        ))
    }
}

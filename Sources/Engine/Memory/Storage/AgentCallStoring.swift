//
//  AgentCallStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

/// AgentCallStoring persists the agent's calls: the event, the call and its arguments together, and
/// then the states the call reaches. It only keeps facts: it runs no tool, performs no gesture and
/// decides on its own neither to skip nor to interrupt a call.
///
/// A conformer writes a call whole or not at all and answers after the commit. A call is identified
/// by its event: the same event with the same request answers `alreadyApplied`, whatever state the
/// call has reached since; other content under that identity is `MemoryStoreError.identity`, with
/// nothing written. An event a capture already stored is checked against the offer and completed
/// with the call, never rewritten: its capture summary and its samples stay as they are. The
/// arguments never change once written; the state and the result move only through `advance`.
public protocol AgentCallStoring: Sendable {

    /// Records a call `planned`: its event (found or created), the call and its arguments.
    func record(_ call: AgentCallRecord) async throws -> MemoryReceipt

    /// Records a batch and every step `planned` in one transaction, after checking the whole group:
    /// each step is a child event of the batch at its position, with the batch's source, stream,
    /// trace, session and application.
    func record(batch: AgentCallRecord, steps: [AgentCallRecord]) async throws -> MemoryReceipt

    /// Moves calls to the states given, in order, in one transaction: all of them or none. A state
    /// already reached with the same result is a retry; `alreadyApplied` when every transition was.
    func advance(_ transitions: [AgentCallTransition]) async throws -> MemoryReceipt

    /// The stored call, or nil when no call has this event.
    func call(_ eventID: String) async throws -> AgentCall?

    /// The calls of a trace in local order, after `localOrder` when given, at most `limit`.
    func calls(inTrace traceID: String, after localOrder: Int64?, limit: Int) async throws -> [AgentCall]

    /// A batch's steps in their positions.
    func steps(ofBatch eventID: String) async throws -> [AgentCall]
}

//
//  TurnCycle.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation
import Memory

/// TurnCycle is the chat's learning cycle for one tool adapter, as one sequence every host uses:
/// `begin` consults recall and opens the ledger for the user's exact request, and returns the prompt
/// to send; `end` closes the ledger, records the report's one event and closes recall's turn.
///
/// The owner calls `end` only after the provider has stopped and in-flight tool calls have drained.
/// Without a living memory the ledger still runs, so a turn is still decided, but nothing is read or
/// written. It installs itself as the adapter's event and observation listener.
@MainActor
public final class TurnCycle {

    /// Start is what `begin` prepared: the turn's identity, what recall contributed, and the prompt.
    public struct Start: Sendable {
        public let turnID: UUID
        public let memory: TurnMemory.Preparation?
        /// The provider prompt: the memory block, when there is one, then the request as written.
        public let prompt: String
    }

    /// End is how the turn ended for memory: the ledger's report and what recording it did.
    public struct End: Sendable {
        public let report: TurnLedger.Report
        /// Nil when no living memory is composed.
        public let recording: TurnRecorder.Outcome?
    }

    private let ledger: TurnLedger
    private let memory: TurnMemory?
    private let recorder: TurnRecorder?

    public init(
        tools       : AutomationTools,
        livingMemory: (any LivingMemoryStoring)?,
        clock       : @escaping () -> Date = { Date() }
    ) {
        let ledger = TurnLedger(clock: clock)
        let memory = livingMemory.map { TurnMemory(store: $0, clock: clock) }
        self.ledger   = ledger
        self.memory   = memory
        self.recorder = livingMemory.map { TurnRecorder(store: $0) }
        tools.onEvent = { ledger.record($0) }
        tools.annotateObservation = { memory?.observed($0) }
    }

    /// Starts a turn for the user's exact request. `sessionIsOpen` is whether a Seat session is open.
    public func begin(_ request: String, sessionIsOpen: Bool) async throws -> Start {
        let turnID = UUID()
        let preparation = await memory?.begin(request: request, turnID: turnID, sessionIsOpen: sessionIsOpen)
        ledger.begin(request: request, followed: preparation?.followed, id: turnID)
        let prompt = try TurnMemory.prompt(for: request, briefing: preparation?.briefing)
        return Start(turnID: turnID, memory: preparation, prompt: prompt)
    }

    /// Ends the open turn, or returns nil when none is open.
    public func end(_ ending: TurnAdmission.Ending) async -> End? {
        defer { memory?.end() }
        guard let report = ledger.finish(ending) else { return nil }
        return End(report: report, recording: await recorder?.record(report))
    }
}

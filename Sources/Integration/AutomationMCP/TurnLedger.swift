//
//  TurnLedger.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
import Memory

/// TurnLedger collects one chat turn's typed tool events and, when the turn has ended, turns them
/// into a `TurnLedger.Report` under `TurnAdmission`: a verified candidate, a kept attempt, or
/// nothing. It is the producer side of learning; it reads and writes no store. The chat's composition
/// hands each report to its one consumer, which decides whether to persist it.
///
/// The owner calls `begin` with the user's exact phrase before the provider runs, forwards every
/// `AutomationEvent`, and calls `finish` only after the provider has stopped and in-flight tool
/// calls have drained, so no event of the turn can arrive after its decision. Events outside a turn,
/// such as a `/status` typed at the prompt, are not part of any turn and are ignored.
@MainActor
public final class TurnLedger {

    /// Report is one ended turn: its identity, the user's phrase, what the tools did, how it ended,
    /// and the decision. A batch is one `.batch` attempt; its steps are kept apart for diagnosis
    /// and never count as direct attempts.
    public struct Report: Sendable, Equatable {
        public let turnID: UUID
        public let request: String
        public let attempts: [TurnAdmission.Attempt]
        public let batchSteps: [AutomationEvent]
        public let ending: TurnAdmission.Ending
        public let decision: TurnAdmission.Decision
        /// When the ledger ended the turn: the event's time, fixed so a repeated delivery is identical.
        public let endedAt: Date

        /// The idempotency key of the memory event this report yields: one per turn, so a
        /// consumer that retries a write whose result was lost cannot count the turn twice.
        public var eventID: String { "turn-\(turnID.uuidString)" }

        /// The memory event to record, or nil when the decision records nothing.
        public var event: ExperienceEvent? { decision.event(id: eventID, at: endedAt) }
    }

    private struct OpenTurn {
        let id: UUID
        let request: String
        var followed: TurnAdmission.FollowedExperience?
        var preparedSteps = 0
        var attempts: [TurnAdmission.Attempt] = []
        var batchSteps: [AutomationEvent] = []
    }

    private let clock: () -> Date
    private var open: OpenTurn?

    /// - Parameter clock: stamps the end of each turn.
    public init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Whether a turn is being collected.
    public var isCollecting: Bool { open != nil }

    /// Starts collecting a turn. `followed` is the remembered experience the turn acts on, when the
    /// caller knows one; the ledger never looks one up. A turn still open is ended as interrupted
    /// and its report returned, so it is never silently lost.
    @discardableResult
    public func begin(
        request : String,
        followed: TurnAdmission.FollowedExperience? = nil,
        id      : UUID = UUID()
    ) -> Report? {
        let abandoned = open == nil ? nil : finish(.interrupted)
        open = OpenTurn(id: id, request: request, followed: followed)
        return abandoned
    }

    /// Freezes the provider's current suggestion before an input starts. If later inputs follow
    /// different experiences, this single-experience ledger abstains from assigning a correction.
    func prepareStep(followed: TurnAdmission.FollowedExperience?) {
        guard var turn = open else { return }
        if turn.preparedSteps == 0 {
            turn.followed = followed
        } else if turn.followed?.id != followed?.id || turn.followed?.context != followed?.context {
            turn.followed = nil
        }
        turn.preparedSteps += 1
        open = turn
    }

    /// Adds one event to the open turn.
    public func record(_ event: AutomationEvent) {
        guard open != nil else { return }
        if event.batchStep != nil {
            open?.batchSteps.append(event)
        } else {
            open?.attempts.append(Self.attempt(event))
        }
    }

    /// Ends the open turn and decides it, or returns nil when no turn is open.
    public func finish(_ ending: TurnAdmission.Ending) -> Report? {
        guard let turn = open else { return nil }
        open = nil
        let decision = TurnAdmission.decide(TurnAdmission.Turn(
            request : turn.request,
            attempts: turn.attempts,
            ending  : ending,
            followed: turn.followed
        ))
        return Report(turnID: turn.id, request: turn.request, attempts: turn.attempts,
                      batchSteps: turn.batchSteps, ending: ending, decision: decision, endedAt: clock())
    }

    /// The attempt one direct call makes. A select keeps its arguments and its dropdown evidence, an
    /// act its arguments and its toggle's or click's evidence, and a failed act the arguments it could
    /// be read with.
    static func attempt(_ event: AutomationEvent) -> TurnAdmission.Attempt {
        let name = event.operation.toolName
        if case .failed = event.result {
            if case .act(let arguments) = event.operation { return .failed(name, act: arguments) }
            return .failed(name)
        }
        switch (event.operation, event.result) {
            case (.status, _), (.windows, _), (.apps, _), (.openSession, _), (.observe, _), (.menus, _), (.resolveAction, _):
                return .preparation(name)
            case (.menu(let path, let expected), .outcome(let kind, let evidence)):
                return .menu(.init(path: path, expectedWindow: expected), kind: kind, evidence: evidence?.menu)
            case (.select(let control, let item), .outcome(let kind, let evidence)):
                return .select(control: control, item: item, kind: kind, evidence: evidence?.dropdown)
            case (.act(let arguments), .outcome(let kind, let evidence)):
                return .act(arguments, kind: kind, evidence: evidence)
            case (.batch, _):
                return .batch
            default:
                return .other(name)
        }
    }
}

extension AutomationEvent.Operation {

    /// The MCP tool name of the operation.
    var toolName: String {
        switch self {
            case .status            : AutomationTool.status.rawValue
            case .windows           : AutomationTool.windows.rawValue
            case .apps              : AutomationTool.apps.rawValue
            case .openSession       : AutomationTool.openSession.rawValue
            case .openRecent        : AutomationTool.openRecent.rawValue
            case .menus             : AutomationTool.menus.rawValue
            case .resolveAction     : AutomationTool.resolveAction.rawValue
            case .menu              : AutomationTool.menu.rawValue
            case .observe           : AutomationTool.observe.rawValue
            case .closeSession      : AutomationTool.closeSession.rawValue
            case .act               : AutomationTool.act.rawValue
            case .select            : AutomationTool.select.rawValue
            case .input(let tool)   : tool.rawValue
            case .batch             : AutomationTool.batch.rawValue
            case .unknown(let name) : name
        }
    }
}

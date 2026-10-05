//
//  SQLiteAgentCallRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SQLiteAgentCallRepository is `AgentCallStoring` over `SQLiteMemoryStore`: a call's event in
/// `memory_events` (through the events' own codec, `SQLiteEventRows.record`), the call in
/// `memory_agent_actions`, and its arguments in `memory_operation_arguments` under the event as
/// their owner, all in one write transaction; then its states, each move in one transaction with
/// the checks it needs. It runs no tool and replays nothing: a retry of the store is a retry of the
/// data. The producers reach it through the integration's memory service, which owns the store.
public struct SQLiteAgentCallRepository: AgentCallStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ call: AgentCallRecord) async throws -> MemoryReceipt {
        guard call.event.parentEventID == nil else { throw AgentCallError.invalidRequest(.stepOutsideBatch) }
        guard call.request.tool != .batch else { throw AgentCallError.invalidRequest(.batchOutsideBatchRecord) }
        return try await store.write { transaction in
            try SQLiteAgentCallRows.record(transaction, call, requestedSteps: nil)
        }
    }

    public func record(batch: AgentCallRecord, steps: [AgentCallRecord]) async throws -> MemoryReceipt {
        try SQLiteAgentCallRows.validate(batch: batch, steps: steps)
        return try await store.write { transaction in
            let receipt = try SQLiteAgentCallRows.record(transaction, batch, requestedSteps: steps.count)
            for step in steps {
                // A batch's steps are written with it, never alone: under a stored batch every step
                // is stored, under a new one none is.
                guard try SQLiteAgentCallRows.record(transaction, step, requestedSteps: nil) == receipt else {
                    throw SQLiteAgentCallRows.batchConflict(batch, steps: steps)
                }
            }
            let stored = try transaction.query(
                "SELECT count(*) FROM memory_events WHERE parent_event_id = ?", [.text(batch.event.eventID)]
            ) { $0.integer(0) ?? -1 }.first ?? -1
            guard stored == Int64(steps.count) else { throw SQLiteAgentCallRows.batchConflict(batch, steps: steps) }
            return receipt
        }
    }

    public func advance(_ transitions: [AgentCallTransition]) async throws -> MemoryReceipt {
        try await store.write { transaction in
            var moved = false
            for transition in transitions {
                moved = try SQLiteAgentCallRows.advance(transaction, transition) || moved
            }
            return moved ? .committed : .alreadyApplied
        }
    }

    public func call(_ eventID: String) async throws -> AgentCall? {
        try await store.read { snapshot in try SQLiteAgentCallRows.call(snapshot, eventID: eventID) }
    }

    public func calls(inTrace traceID: String, after localOrder: Int64?, limit: Int) async throws -> [AgentCall] {
        guard limit > 0 else { return [] }
        return try await store.read { snapshot in
            let ids = try snapshot.query(
                """
                SELECT e.event_id FROM memory_events e JOIN memory_agent_actions a ON a.event_id = e.event_id
                WHERE e.trace_id = ? AND e.local_order > ? ORDER BY e.local_order LIMIT ?
                """,
                [.text(traceID), .integer(localOrder ?? 0), .integer(Int64(limit))]
            ) { try $0.text(0) ?? "" }
            return try ids.compactMap { try SQLiteAgentCallRows.call(snapshot, eventID: $0) }
        }
    }

    public func steps(ofBatch eventID: String) async throws -> [AgentCall] {
        try await store.read { snapshot in
            let ids = try snapshot.query(
                """
                SELECT e.event_id FROM memory_events e JOIN memory_agent_actions a ON a.event_id = e.event_id
                WHERE e.parent_event_id = ? ORDER BY e.parent_position
                """,
                [.text(eventID)]
            ) { try $0.text(0) ?? "" }
            return try ids.compactMap { try SQLiteAgentCallRows.call(snapshot, eventID: $0) }
        }
    }
}

/// SQLiteAgentCallRows is the codec of a call: its row in `memory_agent_actions`, its arguments,
/// and the moves of its state, always inside the caller's transaction or snapshot.
enum SQLiteAgentCallRows {

    /// Stored is a call's row as read: its tool, version, state, the instant it started (kept through
    /// its terminal states, outside the progress the moves are compared on) and the steps a batch
    /// was given.
    struct Stored {
        let localOrder: Int64
        let tool: AgentTool
        let contractVersion: Int
        let progress: AgentCallProgress
        let startedAtMS: Int64?
        let requestedSteps: Int?
        let parentEventID: String?
    }

    // MARK: Recording

    /// Checks a batch and its steps as a whole before anything is written: the batch is a batch
    /// with no parent, it has steps, and each step is a batch step, a child of the batch at its
    /// position, distinct from the others, with the batch's source, stream, trace, session and
    /// application byte for byte.
    static func validate(batch: AgentCallRecord, steps: [AgentCallRecord]) throws {
        func refuse(_ invalidity: AgentCallError.Invalidity) -> AgentCallError { .invalidBatch(invalidity) }
        guard batch.request.tool == .batch else { throw refuse(.notABatch) }
        guard batch.event.parentEventID == nil else { throw refuse(.stepOutsideBatch) }
        guard !steps.isEmpty else { throw refuse(.batchWithoutSteps) }
        let parent = batch.event
        var seen: [[UInt8]] = []
        for (position, step) in steps.enumerated() {
            let event = step.event
            guard step.request.tool.isBatchStep else { throw refuse(.notABatchStep(position: position, tool: step.request.tool)) }
            guard let parentID = event.parentEventID, parentID.utf8.elementsEqual(parent.eventID.utf8),
                  event.parentPosition == position else { throw refuse(.stepParent(position: position)) }
            let id = Array(event.eventID.utf8)
            guard !seen.contains(id), !id.elementsEqual(parent.eventID.utf8) else { throw refuse(.repeatedStep(position: position)) }
            seen.append(id)
            func same(_ a: String?, _ b: String?) -> Bool {
                switch (a, b) {
                    case (nil, nil)       : true
                    case (let a?, let b?) : a.utf8.elementsEqual(b.utf8)
                    default               : false
                }
            }
            let fields: [(String, Bool)] = [
                ("source", event.source == parent.source), ("stream", same(event.streamID, parent.streamID)),
                ("trace", same(event.traceID, parent.traceID)), ("session", same(event.sessionID, parent.sessionID)),
                ("app", same(event.app?.stored.bundleID, parent.app?.stored.bundleID)
                    && same(event.app?.stored.version, parent.app?.stored.version)
                    && same(event.app?.stored.locale, parent.app?.stored.locale)),
            ]
            if let mismatch = fields.first(where: { !$0.1 }) { throw refuse(.stepContext(position: position, field: mismatch.0)) }
        }
    }

    /// Records one call inside the transaction: its event through the events' codec, then the call
    /// and its arguments when the event holds none yet. A stored call is compared exactly (tool,
    /// version, the steps a batch was given, every argument) and answers `alreadyApplied` whatever
    /// state it reached; other content is a conflict.
    static func record(_ transaction: SQLiteTransaction, _ call: AgentCallRecord, requestedSteps: Int?) throws -> MemoryReceipt {
        _ = try SQLiteEventRows.record(transaction, call.event)
        let eventID = call.event.eventID
        if let stored = try stored(transaction, eventID: eventID) {
            let storedRequest = try request(transaction, eventID: eventID, stored: stored)
            guard stored.tool == call.request.tool, stored.requestedSteps == requestedSteps,
                  storedRequest.isExactly(call.request) else {
                throw MemoryStoreError.identity(MemoryIdentityConflict(
                    identity          : eventID,
                    storedFingerprint : "v\(stored.contractVersion)/\(stored.requestedSteps.map(String.init) ?? "-")/\(storedRequest.digest)",
                    offeredFingerprint: "v\(AgentCallContract.version)/\(requestedSteps.map(String.init) ?? "-")/\(call.request.digest)"
                ))
            }
            return .alreadyApplied
        }
        try transaction.execute(
            """
            INSERT INTO memory_agent_actions (event_id, app_id, tool_kind, contract_version, execution_status, requested_count)
            VALUES (?, (SELECT app_id FROM memory_events WHERE event_id = ?), ?, ?, 'planned', ?)
            """,
            [.text(eventID), .text(eventID), .text(call.request.tool.rawValue), .integer(Int64(AgentCallContract.version)),
             requestedSteps.map { .integer(Int64($0)) } ?? .null]
        )
        for argument in call.request.arguments {
            let (kind, column, value): (String, String, SQLiteValue) = switch argument.value {
                case .text(let text)    : ("text", "text_value", .text(text))
                case .integer(let value): ("integer", "integer_value", .integer(value))
                case .real(let value)   : ("real", "real_value", .real(value))
                case .boolean(let flag) : ("boolean", "boolean_value", .integer(flag ? 1 : 0))
            }
            try transaction.execute(
                """
                INSERT INTO memory_operation_arguments (event_id, app_id, argument_name, position, value_kind, \(column))
                VALUES (?, (SELECT app_id FROM memory_agent_actions WHERE event_id = ?), ?, ?, ?, ?)
                """,
                [.text(eventID), .text(eventID), .text(argument.name), .integer(Int64(argument.position)), .text(kind), value]
            )
        }
        return .committed
    }

    static func batchConflict(_ batch: AgentCallRecord, steps: [AgentCallRecord]) -> MemoryStoreError {
        .identity(MemoryIdentityConflict(
            identity          : batch.event.eventID,
            storedFingerprint : "the stored batch and its steps",
            offeredFingerprint: StructuralDigest.fnv1a(steps.map { "\($0.event.eventID)/\($0.request.digest)" }.joined(separator: "\u{1E}"))
        ))
    }

    // MARK: Advancing

    /// Applies one transition: `true` when it moved the call, `false` for a retry of the stored
    /// state. A step starts only once its batch has; a batch concludes with a result only when that
    /// result is the summary its steps allow (`producerSummary`).
    static func advance(_ transaction: SQLiteTransaction, _ transition: AgentCallTransition) throws -> Bool {
        let eventID = transition.eventID, progress = transition.progress
        guard let stored = try stored(transaction, eventID: eventID) else { throw AgentCallError.missingCall(eventID: eventID) }
        try progress.validate(for: stored.tool)
        guard try progress.decision(after: stored.progress, eventID: eventID) else { return false }
        if progress.status == .started, let parentID = stored.parentEventID {
            guard try self.stored(transaction, eventID: parentID)?.progress.status == .started else {
                throw AgentCallError.stepBeforeBatch(eventID: eventID)
            }
        }
        if case .batch(let stopped, let attempted, let verified)? = progress.result {
            guard let summary = try producerSummary(transaction, batchID: eventID, requestedSteps: stored.requestedSteps),
                  summary == BatchSummary(stopped: stopped, attempted: attempted, verified: verified) else {
                throw AgentCallError.batchNotSettled(eventID: eventID)
            }
        }
        let columns = resultColumns(progress)
        let effect  = progress.observedEffect
        // The start is written once, by the `started` move, and kept by every later one.
        try transaction.execute(
            """
            UPDATE memory_agent_actions SET execution_status = ?, started_at_ms = COALESCE(?, started_at_ms), completed_at_ms = ?,
                duration_ms = ?, result_kind = ?, result_message = ?, attempted_count = ?, verified_count = ?,
                observed_effect_kind = ?, observed_effect_text = ?, observed_state_before = ?, observed_state_after = ?
            WHERE event_id = ?
            """,
            [.text(progress.status.rawValue), progress.startedAtMS.map(SQLiteValue.integer) ?? .null,
             progress.endedAtMS.map(SQLiteValue.integer) ?? .null, progress.durationMS.map(SQLiteValue.integer) ?? .null,
             columns.kind, columns.message, columns.attempted, columns.verified,
             effect.map { .text($0.kind) } ?? .null, effect?.title.map(SQLiteValue.text) ?? .null,
             effect?.stateBefore.map { .text($0.rawValue) } ?? .null, effect?.stateAfter.map { .text($0.rawValue) } ?? .null,
             .text(eventID)]
        )
        if let effect {
            for (position, label) in effect.labels.enumerated() {
                try transaction.execute(
                    "INSERT INTO memory_agent_action_effect_labels (event_id, position, label) VALUES (?, ?, ?)",
                    [.text(eventID), .integer(Int64(position)), .text(label)]
                )
            }
        }
        if let result = progress.result { try writeResult(transaction, eventID: eventID, result) }
        return true
    }

    /// Writes the typed rows of a structured result, once, as the call concludes.
    private static func writeResult(_ transaction: SQLiteTransaction, eventID: String, _ result: AgentCallResult) throws {
        switch result {
            case .status(let status):
                try transaction.execute(
                    """
                    INSERT INTO memory_agent_action_status (event_id, session_id, screen_recording, accessibility, post_event)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [.text(eventID), status.sessionID.map(SQLiteValue.text) ?? .null, .integer(status.screenRecording ? 1 : 0),
                     .integer(status.accessibility ? 1 : 0), .integer(status.postEvent ? 1 : 0)]
                )
            case .listing(let listing):
                try transaction.execute(
                    "INSERT INTO memory_agent_action_listings (event_id, listing_kind, hidden_count) VALUES (?, ?, ?)",
                    [.text(eventID), .text(listing.kind.rawValue), .integer(Int64(listing.hiddenCount))]
                )
                for (position, application) in listing.applications.enumerated() {
                    try transaction.execute(
                        """
                        INSERT INTO memory_agent_action_applications
                            (event_id, position, name, bundle_id, pid, app_version, is_running, location)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [.text(eventID), .integer(Int64(position)), .text(application.name), .text(application.bundleID),
                         application.pid.map(SQLiteValue.integer) ?? .null, application.version.map(SQLiteValue.text) ?? .null,
                         application.isRunning.map { .integer($0 ? 1 : 0) } ?? .null,
                         application.location.map(SQLiteValue.text) ?? .null]
                    )
                    for (windowPosition, window) in application.windows.enumerated() {
                        try transaction.execute(
                            """
                            INSERT INTO memory_agent_action_windows (event_id, application_position, position, window_number, title)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                            [.text(eventID), .integer(Int64(position)), .integer(Int64(windowPosition)),
                             .integer(window.number), window.title.map(SQLiteValue.text) ?? .null]
                        )
                    }
                }
            case .observation(let observation):
                let sample = observation.sample
                guard let observationID = try transaction.query(
                    """
                    SELECT observation_id FROM memory_event_observations
                    WHERE event_id = ? AND phase = ? AND sample_ordinal = ? AND observation_kind = 'capture'
                    """,
                    [.text(sample.eventID), .text(sample.phase.rawValue), .integer(Int64(sample.ordinal))]
                ) { $0.integer(0) }.first ?? nil else {
                    throw AgentCallError.missingSample(eventID: eventID, sample: sample)
                }
                try transaction.execute(
                    """
                    INSERT INTO memory_agent_action_observations
                        (event_id, session_id, session_revision, observed_at_ms, sample_event_id, sample_phase, sample_ordinal,
                         sample_observation_id, sample_kind)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'capture')
                    """,
                    [.text(eventID), .text(observation.sessionID), .integer(observation.sessionRevision),
                     .integer(observation.observedAtMS), .text(sample.eventID), .text(sample.phase.rawValue),
                     .integer(Int64(sample.ordinal)), .integer(observationID)]
                )
            case .outcome, .batch, .closed, .error:
                break
        }
    }

    /// BatchSummary is what a concluded batch says about its steps: whether it stopped, how many
    /// steps it attempted and how many it accepted.
    struct BatchSummary: Equatable {
        let stopped: Bool
        let attempted: Int
        let verified: Int
    }

    /// The summary the current producer (`AutomationTools.call`, its batch) writes for the batch's
    /// stored steps, or nil when no run of it could have left them so. In position order: a step is
    /// accepted when it completed with `found_acted`, or with `acted_noop` for `act` with
    /// `set_toggle`; the first step that completed with any other outcome, or failed, stops the
    /// batch; every step after the stop is skipped, and no step is skipped before it. A cancelled or
    /// interrupted step, one still open, or a count other than the batch's requested steps admits no
    /// summary. The rule is the producer's, not a verdict on any step's or task's result.
    static func producerSummary(_ handle: some SQLiteQuerying, batchID: String, requestedSteps: Int?) throws -> BatchSummary? {
        let ids = try handle.query(
            "SELECT event_id FROM memory_events WHERE parent_event_id = ? ORDER BY parent_position", [.text(batchID)]
        ) { try $0.text(0) ?? "" }
        guard ids.count == requestedSteps else { return nil }
        var attempted = 0, verified = 0, stopped = false
        for id in ids {
            guard let step = try stored(handle, eventID: id) else { return nil }
            if stopped {
                guard step.progress.status == .skipped else { return nil }
                continue
            }
            switch (step.progress.status, step.progress.result) {
                case (.completed, .outcome(let kind, _)?):
                    attempted += 1
                    var accepted = kind == .foundActed
                    if kind == .actedNoop, case .act(_, .setToggle, _, _) = try request(handle, eventID: id, stored: step) {
                        accepted = true
                    }
                    if accepted { verified += 1 } else { stopped = true }
                case (.failed, _):
                    attempted += 1
                    stopped = true
                default:
                    return nil
            }
        }
        return BatchSummary(stopped: stopped, attempted: attempted, verified: verified)
    }

    private static func resultColumns(_ progress: AgentCallProgress)
        -> (kind: SQLiteValue, message: SQLiteValue, attempted: SQLiteValue, verified: SQLiteValue) {
        switch progress.result {
            case nil:
                return (.null, .null, .null, .null)
            case .outcome(let kind, let message)?:
                return (.text(kind.rawValue), .text(message), .null, .null)
            case .batch(let stopped, let attempted, let verified)?:
                return (.text(stopped ? "stopped" : "completed"), .null, .integer(Int64(attempted)), .integer(Int64(verified)))
            case .closed(let message)?:
                return (.text("closed"), .text(message), .null, .null)
            case .error(let message)?:
                return (.text("error"), .text(message), .null, .null)
            case .status?:
                return (.text("status"), .null, .null, .null)
            case .listing?:
                return (.text("listing"), .null, .null, .null)
            case .observation?:
                return (.text("observation"), .null, .null, .null)
        }
    }

    // MARK: Reading

    /// The stored call row of an event, or nil, refusing a tool, a status or a result this
    /// contract does not know, an observed effect with only one of its two columns, and a result
    /// or an effect that does not go with the call's tool and state.
    static func stored(_ handle: some SQLiteQuerying, eventID: String) throws -> Stored? {
        try handle.query(
            """
            SELECT e.local_order, a.tool_kind, a.contract_version, a.execution_status, a.completed_at_ms, a.result_kind,
                   a.result_message, a.observed_effect_kind, a.observed_effect_text, a.requested_count, a.attempted_count,
                   a.verified_count, e.parent_event_id, a.started_at_ms, a.duration_ms, a.observed_state_before,
                   a.observed_state_after
            FROM memory_agent_actions a JOIN memory_events e ON e.event_id = a.event_id
            WHERE a.event_id = ?
            """,
            [.text(eventID)]
        ) { row -> Stored in
            func refuse(_ malformation: AgentCallError.Malformation) -> AgentCallError {
                .malformedCall(eventID: eventID, malformation: malformation)
            }
            let toolCode = try row.text(1) ?? ""
            guard let tool = AgentTool(rawValue: toolCode), tool.rawValue.utf8.elementsEqual(toolCode.utf8) else {
                throw refuse(.unknownTool(toolCode))
            }
            let version = Int(row.integer(2) ?? 0)
            guard version == AgentCallContract.version else {
                throw AgentCallError.unsupportedContractVersion(eventID: eventID, version: version)
            }
            let statusCode = try row.text(3) ?? ""
            guard let status = AgentCallStatus(rawValue: statusCode) else { throw refuse(.unknownStatus(statusCode)) }
            var observed: ObservedEffect?
            if let effectKind = try row.text(7) {
                let labels = try handle.query(
                    "SELECT position, label FROM memory_agent_action_effect_labels WHERE event_id = ? ORDER BY position",
                    [.text(eventID)]
                ) { (Int($0.integer(0) ?? -1), try $0.text(1) ?? "") }
                guard labels.enumerated().allSatisfy({ $0.offset == $0.element.0 }) else {
                    throw refuse(.positionsNotContiguous("effect labels"))
                }
                do {
                    observed = try ObservedEffect(kind: effectKind, title: try row.text(8), stateBefore: try row.text(15),
                                                  stateAfter: try row.text(16), labels: labels.map(\.1))
                } catch AgentCallError.invalidProgress(.effectShape(let what)) {
                    throw refuse(.resultShape("observed_effect: \(what)"))
                }
            } else if try row.text(8) != nil || row.text(15) != nil || row.text(16) != nil {
                throw refuse(.resultShape("observed_effect"))
            }
            let requested = row.integer(9)
            guard (tool == .batch) == (requested != nil), requested.map({ $0 >= 1 }) ?? true else {
                throw refuse(.resultShape("requested_count"))
            }
            let kind = try row.text(5), message = try row.text(6), attempted = row.integer(10), verified = row.integer(11)
            let result: AgentCallResult?
            switch kind {
                case nil:
                    guard message == nil else { throw refuse(.resultShape("result_message")) }
                    result = nil
                case "error"?, "closed"?:
                    guard let message else { throw refuse(.resultShape("result_message")) }
                    result = kind == "error" ? .error(message: message) : .closed(message: message)
                case "status"?, "listing"?, "observation"?:
                    guard message == nil else { throw refuse(.resultShape("result_message")) }
                    result = try structuredResult(handle, eventID: eventID, kind: kind ?? "")
                case let code? where tool == .batch && (code == "completed" || code == "stopped"):
                    guard message == nil, let attempted, let verified else { throw refuse(.resultShape("batch")) }
                    result = .batch(stopped: code == "stopped", attempted: Int(attempted), verified: Int(verified))
                case let code?:
                    guard tool.isBatchStep, let outcome = ActOutcomeKind(rawValue: code), outcome.rawValue.utf8.elementsEqual(code.utf8) else {
                        throw refuse(.unknownCode(argument: "result_kind", code: code))
                    }
                    guard let message else { throw refuse(.resultShape("result_message")) }
                    result = .outcome(outcome, message: message)
            }
            if case .batch? = result {} else if attempted != nil || verified != nil { throw refuse(.resultShape("counts")) }
            // The start stays out of the progress: the moves are compared on status, result, end and
            // effect, and a terminal move never carries the start it keeps.
            let startedAtMS = row.integer(13)
            if startedAtMS != nil, status == .planned { throw refuse(.resultShape("started_at_ms")) }
            let progress = AgentCallProgress(status, result: result, endedAtMS: row.integer(4), durationMS: row.integer(14),
                                             observedEffect: observed)
            do {
                try progress.validate(for: tool)
            } catch AgentCallError.invalidProgress(let invalidity) {
                throw refuse(.resultShape("\(invalidity)"))
            }
            return Stored(localOrder: row.integer(0) ?? 0, tool: tool, contractVersion: version, progress: progress,
                          startedAtMS: startedAtMS, requestedSteps: requested.map { Int($0) }, parentEventID: try row.text(12))
        }.first
    }

    /// The typed rows of a structured result, rebuilt; a row that is missing or does not fit its
    /// kind is a malformed call.
    private static func structuredResult(_ handle: some SQLiteQuerying, eventID: String, kind: String) throws -> AgentCallResult {
        func refuse(_ what: String) -> AgentCallError { .malformedCall(eventID: eventID, malformation: .resultShape(what)) }
        switch kind {
            case "status":
                guard let status = try handle.query(
                    "SELECT session_id, screen_recording, accessibility, post_event FROM memory_agent_action_status WHERE event_id = ?",
                    [.text(eventID)]
                ) { row in
                    StatusResult(sessionID: try row.text(0), screenRecording: row.integer(1) == 1,
                                 accessibility: row.integer(2) == 1, postEvent: row.integer(3) == 1)
                }.first else { throw refuse("status row") }
                return .status(status)
            case "listing":
                guard let listing = try handle.query(
                    "SELECT listing_kind, hidden_count FROM memory_agent_action_listings WHERE event_id = ?", [.text(eventID)]
                ) { (try $0.text(0) ?? "", Int($0.integer(1) ?? -1)) }.first else { throw refuse("listing row") }
                guard let listingKind = ListingResult.Kind(rawValue: listing.0) else { throw refuse("listing kind \(listing.0)") }
                let windows = try handle.query(
                    """
                    SELECT application_position, position, window_number, title FROM memory_agent_action_windows
                    WHERE event_id = ? ORDER BY application_position, position
                    """,
                    [.text(eventID)]
                ) { (Int($0.integer(0) ?? -1), Int($0.integer(1) ?? -1), ListedWindow(number: $0.integer(2) ?? 0, title: try $0.text(3))) }
                let applications = try handle.query(
                    """
                    SELECT position, name, bundle_id, pid, app_version, is_running, location FROM memory_agent_action_applications
                    WHERE event_id = ? ORDER BY position
                    """,
                    [.text(eventID)]
                ) { row -> (Int, ListedApplication) in
                    let position = Int(row.integer(0) ?? -1)
                    let own = windows.filter { $0.0 == position }
                    guard own.enumerated().allSatisfy({ $0.offset == $0.element.1 }) else {
                        throw refuse("window positions of application \(position)")
                    }
                    return (position, ListedApplication(
                        name: try row.text(1) ?? "", bundleID: try row.text(2) ?? "", pid: row.integer(3), version: try row.text(4),
                        isRunning: row.integer(5).map { $0 == 1 }, location: try row.text(6), windows: own.map(\.2)
                    ))
                }
                guard applications.enumerated().allSatisfy({ $0.offset == $0.element.0 }) else {
                    throw refuse("application positions")
                }
                guard Set(windows.map(\.0)).isSubset(of: Set(applications.map(\.0))) else { throw refuse("windows without application") }
                return .listing(ListingResult(kind: listingKind, applications: applications.map(\.1), hiddenCount: listing.1))
            case "observation":
                guard let observation = try handle.query(
                    """
                    SELECT session_id, session_revision, observed_at_ms, sample_event_id, sample_phase, sample_ordinal
                    FROM memory_agent_action_observations WHERE event_id = ?
                    """,
                    [.text(eventID)]
                ) { row -> ObservationResult in
                    guard let phase = CapturePhase(rawValue: try row.text(4) ?? "") else { throw refuse("sample phase") }
                    return ObservationResult(
                        sessionID: try row.text(0) ?? "", sessionRevision: row.integer(1) ?? -1, observedAtMS: row.integer(2) ?? 0,
                        sample: CaptureSampleKey(eventID: try row.text(3) ?? "", phase: phase, ordinal: Int(row.integer(5) ?? -1))
                    )
                }.first else { throw refuse("observation row") }
                return .observation(observation)
            default:
                throw refuse("result_kind \(kind)")
        }
    }

    /// A stored call's request, rebuilt from its arguments under the contract, refusing a row with
    /// another owner's columns or a kind this owner does not admit.
    static func request(_ handle: some SQLiteQuerying, eventID: String, stored: Stored) throws -> AgentCallRequest {
        let arguments = try handle.query(
            """
            SELECT argument_name, position, value_kind, text_value, integer_value, real_value, boolean_value,
                   operation_id, brain_application_id, route_id, parameter_id, anchor_id, menu_command_id
            FROM memory_operation_arguments WHERE event_id = ? ORDER BY argument_id
            """,
            [.text(eventID)]
        ) { row -> BrainArgument in
            func refuse(_ malformation: AgentCallError.Malformation) -> AgentCallError {
                .malformedCall(eventID: eventID, malformation: malformation)
            }
            let name = try row.text(0) ?? ""
            for (index, column) in [(7, "operation_id"), (8, "brain_application_id"), (9, "route_id"), (10, "parameter_id"),
                                    (11, "anchor_id"), (12, "menu_command_id")] where !row.isNull(index) {
                throw refuse(.forbiddenColumn(column))
            }
            let set = [3, 4, 5, 6].filter { !row.isNull($0) }
            let value: BrainArgument.Value
            switch (try row.text(2) ?? "", set) {
                case ("text", [3])   : value = .text(try row.text(3) ?? "")
                case ("integer", [4]): value = .integer(row.integer(4) ?? 0)
                case ("real", [5])   : value = .real(row.real(5) ?? 0)
                case ("boolean", [6]): value = .boolean(row.integer(6) == 1)
                default              : throw refuse(.argumentKindMismatch(name))
            }
            return BrainArgument(name: name, position: Int(row.integer(1) ?? -1), value: value)
        }
        return try AgentCallRequest(tool: stored.tool, arguments: arguments, eventID: eventID)
    }

    /// The stored call of an event, whole, or nil when the event holds none. A concluded batch's
    /// summary is read only when it is the one its steps allow; a summary they contradict is a
    /// malformed row, never shown as a trace.
    static func call(_ handle: some SQLiteQuerying, eventID: String) throws -> AgentCall? {
        guard let stored = try stored(handle, eventID: eventID),
              let event = try SQLiteEventRows.read(handle, eventID: eventID) else { return nil }
        if case .batch(let stopped, let attempted, let verified)? = stored.progress.result {
            guard try producerSummary(handle, batchID: eventID, requestedSteps: stored.requestedSteps)
                    == BatchSummary(stopped: stopped, attempted: attempted, verified: verified) else {
                throw AgentCallError.malformedCall(eventID: eventID, malformation: .resultShape("batch summary"))
            }
        }
        return AgentCall(
            localOrder     : stored.localOrder,
            event          : event,
            request        : try request(handle, eventID: eventID, stored: stored),
            contractVersion: stored.contractVersion,
            progress       : stored.progress,
            requestedSteps : stored.requestedSteps,
            startedAtMS    : stored.startedAtMS
        )
    }
}

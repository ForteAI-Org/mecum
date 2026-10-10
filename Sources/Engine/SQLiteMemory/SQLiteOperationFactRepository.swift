//
//  SQLiteOperationFactRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import Foundation
import Memory

/// SQLiteOperationFactRepository is `OperationFactStoring` over `SQLiteMemoryStore`: the essential facts of
/// a call, each group in one write transaction through the codecs the other repositories use. The opening
/// writes the call planned and started, its place in the task attempt and its withheld values; the
/// conclusion writes the samples, the terminal state with its result, the effect, the verifications
/// (event, verdict row, condition, limits, samples) and the declared gaps. Offered again with the same
/// values, every part is `alreadyApplied`; another content under one of its identities is the typed
/// conflict of that part, and the whole transaction writes nothing.
public struct SQLiteOperationFactRepository: OperationFactStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func open(_ opening: OperationOpening) async throws -> MemoryReceipt {
        let call = opening.call
        guard call.event.parentEventID == nil else { throw AgentCallError.invalidRequest(.stepOutsideBatch) }
        guard call.request.tool != .batch else { throw AgentCallError.invalidRequest(.batchOutsideBatchRecord) }
        return try await store.write { transaction in
            var receipts = [try SQLiteAgentCallRows.record(transaction, call, requestedSteps: nil)]
            let start = AgentCallTransition(call.event.eventID, .started(atMS: opening.startedAtMS))
            receipts.append(try SQLiteAgentCallRows.advance(transaction, start) ? .committed : .alreadyApplied)
            if let attribution = opening.attribution {
                receipts.append(
                    try SQLiteOperationFactRows.attribute(transaction, call.event.eventID, attribution, role: .action)
                )
            }
            for redaction in opening.redactions {
                receipts.append(try SQLiteOperationFactRows.record(transaction, redaction))
            }
            return receipts.contains(.committed) ? .committed : .alreadyApplied
        }
    }

    public func open(batch opening: BatchOpening) async throws -> MemoryReceipt {
        try SQLiteAgentCallRows.validate(batch: opening.batch, steps: opening.steps)
        return try await store.write { transaction in
            let batch = opening.batch
            var receipts = [try SQLiteAgentCallRows.record(transaction, batch, requestedSteps: opening.steps.count)]
            for step in opening.steps {
                guard try SQLiteAgentCallRows.record(transaction, step, requestedSteps: nil) == receipts[0] else {
                    throw SQLiteAgentCallRows.batchConflict(batch, steps: opening.steps)
                }
            }
            let start = AgentCallTransition(batch.event.eventID, .started(atMS: opening.startedAtMS))
            receipts.append(try SQLiteAgentCallRows.advance(transaction, start) ? .committed : .alreadyApplied)
            if let attribution = opening.attribution {
                receipts.append(
                    try SQLiteOperationFactRows.attribute(transaction, batch.event.eventID, attribution, role: .context)
                )
            }
            for redaction in opening.redactions {
                receipts.append(try SQLiteOperationFactRows.record(transaction, redaction))
            }
            return receipts.contains(.committed) ? .committed : .alreadyApplied
        }
    }

    public func start(
        step eventID: String,
        atMS        : Int64,
        attribution : TaskCallAttribution?
    ) async throws -> MemoryReceipt {
        try await store.write { transaction in
            var receipts = [
                try SQLiteAgentCallRows.advance(transaction, AgentCallTransition(eventID, .started(atMS: atMS)))
                    ? MemoryReceipt.committed : .alreadyApplied
            ]
            if let attribution {
                receipts.append(try SQLiteOperationFactRows.attribute(transaction, eventID, attribution, role: .action))
            }
            return receipts.contains(.committed) ? .committed : .alreadyApplied
        }
    }

    public func record(samples: [CaptureSample], redactions: [ValueRedaction] = []) async throws -> MemoryReceipt {
        for sample in samples { try sample.validate() }
        return try await store.write { transaction in
            var receipts: [MemoryReceipt] = []
            for sample in samples { receipts.append(try SQLiteOperationFactRows.record(transaction, sample)) }
            for redaction in redactions { receipts.append(try SQLiteOperationFactRows.record(transaction, redaction)) }
            return receipts.contains(.committed) ? .committed : .alreadyApplied
        }
    }

    public func conclude(_ conclusion: OperationConclusion) async throws -> MemoryReceipt {
        for sample in conclusion.samples { try sample.validate() }
        for verification in conclusion.verifications { _ = try verification.record() }
        return try await store.write { transaction in
            var receipts: [MemoryReceipt] = []
            for sample in conclusion.samples {
                receipts.append(try SQLiteOperationFactRows.record(transaction, sample))
            }
            for withdrawal in conclusion.withdrawn {
                receipts.append(try SQLiteOperationFactRows.withdraw(transaction, withdrawal))
            }
            receipts.append(try SQLiteAgentCallRows.advance(transaction, conclusion.end) ? .committed : .alreadyApplied)
            if let effect = conclusion.effect {
                receipts.append(try SQLiteOperationFactRows.record(transaction, effect))
            }
            for verification in conclusion.verifications {
                receipts.append(try SQLiteOperationFactRows.record(transaction, verification))
            }
            for redaction in conclusion.redactions {
                receipts.append(try SQLiteOperationFactRows.record(transaction, redaction))
            }
            for gap in conclusion.unsaved {
                receipts.append(try SQLiteOperationFactRows.record(transaction, gap))
            }
            return receipts.contains(.committed) ? .committed : .alreadyApplied
        }
    }

    public func effect(of callEventID: String) async throws -> OperationEffect? {
        try await store.read { snapshot in try SQLiteOperationFactRows.effect(snapshot, callEventID) }
    }

    public func verifications(of callEventID: String) async throws -> [OperationVerification] {
        try await store.read { snapshot in
            let ids = try snapshot.query(
                "SELECT event_id FROM memory_operation_verifications WHERE call_event_id = ? ORDER BY event_id",
                [.text(callEventID)]
            ) { try $0.text(0) ?? "" }
            return try ids.compactMap { try SQLiteOperationFactRows.verification(snapshot, $0) }
        }
    }

    public func redactions(of eventID: String) async throws -> [ValueRedaction] {
        try await store.read { snapshot in try SQLiteOperationFactRows.redactions(snapshot, eventID) }
    }

    public func attribution(of callEventID: String) async throws -> TaskCallAttribution? {
        try await store.read { snapshot in try SQLiteOperationFactRows.attribution(snapshot, callEventID) }
    }

    public func recordingGaps(of callEventID: String) async throws -> [OperationRecordingGap] {
        try await store.read { snapshot in try SQLiteOperationFactRows.recordingGaps(snapshot, callEventID) }
    }
}

/// SQLiteOperationFactRows is the codec of the operation facts schema 2 adds, inside the caller's
/// transaction or snapshot.
enum SQLiteOperationFactRows {

    // MARK: Attribution

    /// Places a call in the attempt at the next position, with the revision it began under, once: a
    /// retry of the same attribution is `alreadyApplied`, another attempt or revision a conflict. The
    /// attempt must be running and of the task named, the revision one of the task's.
    static func attribute(_ transaction: SQLiteTransaction, _ eventID: String, _ attribution: TaskCallAttribution,
                          role: TaskEventRole) throws -> MemoryReceipt {
        if let stored = try self.attribution(transaction, eventID) {
            guard stored == attribution else {
                throw SQLiteFactRows.conflict("\(eventID):attribution", stored: "\(stored)", offered: "\(attribution)")
            }
            return .alreadyApplied
        }
        guard let attempt = try SQLiteTaskContextRows.attempt(transaction, attribution.attemptID),
              attempt.attempt.taskID.utf8.elementsEqual(attribution.taskID.utf8), attempt.status == .inProgress else {
            throw OperationFactError.attemptNotRunning(attemptID: attribution.attemptID)
        }
        guard try SQLiteTaskContextRows.revision(transaction, attribution.taskID, attribution.revision) != nil else {
            throw TaskContextError.staleRevision(taskID: attribution.taskID, expected: attribution.revision, current: 0)
        }
        let next = try transaction.query(
            "SELECT ifnull(max(position) + 1, 0) FROM memory_task_events WHERE task_occurrence_id = ?",
            [.text(attribution.attemptID)]
        ) { $0.integer(0) ?? 0 }.first ?? 0
        _ = try SQLiteTaskRows.record(transaction, try TaskMembership(
            taskOccurrenceID: attribution.attemptID, eventID: eventID, position: next, role: role
        ))
        try transaction.execute(
            """
            INSERT INTO memory_task_call_revisions (event_id, task_occurrence_id, task_id, revision)
            VALUES (?, ?, ?, ?)
            """,
            [.text(eventID), .text(attribution.attemptID), .text(attribution.taskID),
             .integer(Int64(attribution.revision))]
        )
        return .committed
    }

    static func attribution(_ handle: some SQLiteQuerying, _ eventID: String) throws -> TaskCallAttribution? {
        try handle.query(
            "SELECT task_id, task_occurrence_id, revision FROM memory_task_call_revisions WHERE event_id = ?",
            [.text(eventID)]
        ) {
            try TaskCallAttribution(
                taskID: try $0.text(0) ?? "",
                attemptID: try $0.text(1) ?? "",
                revision: Int($0.integer(2) ?? 0)
            )
        }.first
    }

    // MARK: Samples

    /// A sample of an event the archive holds, once by its key: the same sample again is
    /// `alreadyApplied`, another under its key a conflict, a sample of an unknown event refused.
    static func record(_ transaction: SQLiteTransaction, _ sample: CaptureSample) throws -> MemoryReceipt {
        guard try SQLiteEventRows.appID(transaction, eventID: sample.key.eventID) != nil else {
            throw ObservationContractError.missingEvent(eventID: sample.key.eventID)
        }
        if let stored = try SQLiteObservationRows.sample(transaction, key: sample.key) {
            guard stored == sample else {
                throw MemoryStoreError.identity(MemoryIdentityConflict(
                    identity          : "\(sample.key.eventID):\(sample.key.phase.rawValue):\(sample.key.ordinal)",
                    storedFingerprint : stored.fingerprint,
                    offeredFingerprint: sample.fingerprint
                ))
            }
            return .alreadyApplied
        }
        try SQLiteObservationRows.insert(transaction, sample)
        try SQLiteEventRows.refreshCaptureStatus(transaction, eventID: sample.key.eventID)
        return .committed
    }

    // MARK: Effects

    static func record(_ transaction: SQLiteTransaction, _ effect: OperationEffect) throws -> MemoryReceipt {
        if let stored = try self.effect(transaction, effect.callEventID) {
            guard stored == effect else {
                throw SQLiteFactRows.conflict("\(effect.callEventID):effect", stored: "\(stored)", offered: "\(effect)")
            }
            return .alreadyApplied
        }
        try transaction.execute(
            """
            INSERT INTO memory_call_effects (event_id, performed, substitute, not_sent_reason, target_element_id,
                                             target_role, target_label, target_section, checked)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(effect.callEventID), .text(effect.performed.rawValue), text(effect.substitute),
             text(effect.notSentReason)]
                + target(effect.target) + [.integer(effect.checked ? 1 : 0)]
        )
        return .committed
    }

    static func effect(_ handle: some SQLiteQuerying, _ eventID: String) throws -> OperationEffect? {
        try handle.query(
            """
            SELECT performed, substitute, not_sent_reason, target_element_id, target_role, target_label,
                   target_section, checked
            FROM memory_call_effects WHERE event_id = ?
            """,
            [.text(eventID)]
        ) { row in
            let code = try row.text(0) ?? ""
            guard let performed = OperationCheck.Performed(rawValue: code) else {
                throw malformed("memory_call_effects", eventID, "performed")
            }
            return try OperationEffect(callEventID: eventID, performed: performed, substitute: try row.text(1),
                                       notSentReason: try row.text(2), target: try target(row, from: 3),
                                       checked: row.integer(7) == 1)
        }.first
    }

    // MARK: Verifications

    static func record(
        _ transaction : SQLiteTransaction,
        _ verification: OperationVerification
    ) throws -> MemoryReceipt {
        let eventID = verification.event.eventID
        if let stored = try self.verification(transaction, eventID) {
            guard stored.isExactly(verification) else {
                throw SQLiteFactRows.conflict(eventID, stored: "\(stored.check)", offered: "\(verification.check)")
            }
            return .alreadyApplied
        }
        guard try SQLiteAgentCallRows.call(transaction, eventID: verification.callEventID) != nil else {
            throw OperationFactError.missingCall(eventID: verification.callEventID)
        }
        let base = try verification.record()
        _ = try SQLiteEventRows.record(transaction, base.event)
        try transaction.execute(
            """
            INSERT INTO memory_verifications (event_id, scope, method, verdict, expected_text, observed_text)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(eventID), .text(base.scope.rawValue), .text(base.method.rawValue), .text(base.verdict.rawValue),
             text(base.expectedText), text(base.observedText)]
        )
        let check = verification.check
        try transaction.execute(
            """
            INSERT INTO memory_operation_verifications (event_id, call_event_id, contract_version, condition_kind,
                                                        method_version, performed, substitute, target_element_id,
                                                        target_role, target_label, target_section)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(eventID), .text(verification.callEventID), .integer(Int64(OperationFactContract.version)),
             .text(check.condition.rawValue), .text(check.methodVersion), .text(check.performed.rawValue),
             text(check.substitute)]
                + target(check.target)
        )
        for (position, limit) in check.limits.enumerated() {
            try transaction.execute(
                "INSERT INTO memory_operation_verification_limits (event_id, position, limit_kind) VALUES (?, ?, ?)",
                [.text(eventID), .integer(Int64(position)), .text(limit.rawValue)]
            )
        }
        for (position, sample) in verification.samples.enumerated() {
            let found = try transaction.query(
                """
                SELECT observation_id FROM memory_event_observations
                WHERE event_id = ? AND phase = ? AND sample_ordinal = ? AND observation_kind = 'capture'
                """,
                [.text(sample.eventID), .text(sample.phase.rawValue), .integer(Int64(sample.ordinal))],
                { $0.integer(0) }
            )
            guard let observation = found.first ?? nil else {
                throw AgentCallError.missingSample(eventID: verification.callEventID, sample: sample)
            }
            try transaction.execute(
                """
                INSERT INTO memory_operation_verification_samples (event_id, position, sample_observation_id,
                                                                   sample_event_id, sample_phase, sample_ordinal)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(eventID), .integer(Int64(position)), .integer(observation), .text(sample.eventID),
                 .text(sample.phase.rawValue), .integer(Int64(sample.ordinal))]
            )
        }
        return .committed
    }

    static func verification(_ handle: some SQLiteQuerying, _ eventID: String) throws -> OperationVerification? {
        guard let row = try handle.query(
            """
            SELECT v.call_event_id, v.condition_kind, v.method_version, v.performed, v.substitute, v.target_element_id,
                   v.target_role, v.target_label, v.target_section, b.method, b.verdict, b.expected_text,
                   b.observed_text
            FROM memory_operation_verifications v JOIN memory_verifications b ON b.event_id = v.event_id
            WHERE v.event_id = ?
            """,
            [.text(eventID)],
            { row in
                (call: try row.text(0) ?? "", condition: try row.text(1) ?? "", version: try row.text(2) ?? "",
                 performed: try row.text(3) ?? "", substitute: try row.text(4), target: try target(row, from: 5),
                 method: try row.text(9) ?? "", verdict: try row.text(10) ?? "", expected: try row.text(11),
                 observed: try row.text(12))
            }
        ).first, let event = try SQLiteEventRows.read(handle, eventID: eventID) else { return nil }
        guard let condition = OperationCheck.Condition(rawValue: row.condition),
              let performed = OperationCheck.Performed(rawValue: row.performed),
              let method = VerificationMethod(rawValue: row.method)?.oracleMethod,
              let verdict = OperationCheck.Verdict(rawValue: row.verdict) else {
            throw malformed("memory_operation_verifications", eventID, "condition, performed, method or verdict")
        }
        let limits = try handle.query(
            "SELECT limit_kind FROM memory_operation_verification_limits WHERE event_id = ? ORDER BY position",
            [.text(eventID)]
        ) { row -> OperationCheck.Limit in
            let code = try row.text(0) ?? ""
            guard let limit = OperationCheck.Limit(rawValue: code) else {
                throw malformed("memory_operation_verification_limits", eventID, "limit_kind")
            }
            return limit
        }
        let samples = try handle.query(
            """
            SELECT sample_event_id, sample_phase, sample_ordinal FROM memory_operation_verification_samples
            WHERE event_id = ? ORDER BY position
            """,
            [.text(eventID)]
        ) { row -> CaptureSampleKey in
            let phase = try row.text(1) ?? ""
            guard let known = CapturePhase(rawValue: phase) else {
                throw malformed("memory_operation_verification_samples", eventID, "phase")
            }
            return CaptureSampleKey(eventID: try row.text(0) ?? "", phase: known, ordinal: Int(row.integer(2) ?? 0))
        }
        let check = OperationCheck(condition: condition, method: method, methodVersion: row.version, verdict: verdict,
                                   expected: row.expected, observed: row.observed, limits: limits, performed: performed,
                                   substitute: row.substitute, target: row.target)
        return try OperationVerification(event: event, callEventID: row.call, check: check, samples: samples)
    }

    // MARK: Redactions

    /// Declares a gap once by its location: the same location again adds nothing, whatever reason it
    /// gives, since the value is withheld either way.
    static func record(_ transaction: SQLiteTransaction, _ redaction: ValueRedaction) throws -> MemoryReceipt {
        let location = columns(redaction.location)
        let exists = try transaction.query(
            """
            SELECT count(*) FROM memory_value_redactions WHERE event_id = ? AND location_kind = ?
              AND argument_name IS ? AND argument_position IS ? AND condition_kind IS ? AND sample_phase IS ?
              AND sample_ordinal IS ? AND element_position IS ?
            """,
            [.text(redaction.eventID)] + location
        ) { $0.integer(0) ?? 0 }.first ?? 0
        if exists > 0 { return .alreadyApplied }
        try transaction.execute(
            """
            INSERT INTO memory_value_redactions (event_id, location_kind, argument_name, argument_position,
                                                 condition_kind, sample_phase, sample_ordinal, element_position, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(redaction.eventID)] + location + [.text(redaction.reason.rawValue)]
        )
        return .committed
    }

    /// Writes a part of a call's end saved without it, once: the same part with another reason or
    /// detail is another fact under the same identity.
    static func record(_ transaction: SQLiteTransaction, _ gap: OperationRecordingGap) throws -> MemoryReceipt {
        let stored = try recordingGaps(transaction, gap.callEventID).first { $0.part == gap.part }
        if let stored {
            guard stored == gap else {
                throw SQLiteFactRows.conflict(
                    "\(gap.callEventID)/\(gap.part.rawValue)",
                    stored : "\(stored.reason.rawValue)/\(stored.detail ?? "")",
                    offered: "\(gap.reason.rawValue)/\(gap.detail ?? "")"
                )
            }
            return .alreadyApplied
        }
        try transaction.execute(
            "INSERT INTO memory_call_recording_gaps (event_id, part, reason, detail) VALUES (?, ?, ?, ?)",
            [.text(gap.callEventID), .text(gap.part.rawValue), .text(gap.reason.rawValue),
             gap.detail.map(SQLiteValue.text) ?? .null]
        )
        return .committed
    }

    /// The parts of a call's end saved without them, in the order of `OperationRecordingGap.Part`.
    static func recordingGaps(_ handle: some SQLiteQuerying, _ callEventID: String) throws -> [OperationRecordingGap] {
        let rows = try handle.query(
            "SELECT part, reason, detail FROM memory_call_recording_gaps WHERE event_id = ?",
            [.text(callEventID)]
        ) { row -> OperationRecordingGap in
            guard let part = OperationRecordingGap.Part(rawValue: try row.text(0) ?? ""),
                  let reason = OperationRecordingGap.Reason(rawValue: try row.text(1) ?? "") else {
                throw malformed("memory_call_recording_gaps", callEventID, "part or reason")
            }
            return try OperationRecordingGap(
                callEventID: callEventID,
                part       : part,
                reason     : reason,
                detail     : try row.text(2)
            )
        }
        let order = OperationRecordingGap.Part.allCases
        return rows.sorted { order.firstIndex(of: $0.part)! < order.firstIndex(of: $1.part)! }
    }

    /// Replaces an argument the opening kept with the marker, and declares why, once.
    static func withdraw(_ transaction: SQLiteTransaction, _ redaction: ValueRedaction) throws -> MemoryReceipt {
        guard case .argument(let name, let position) = redaction.location else {
            throw OperationFactError.invalid(.otherEvent)
        }
        let marker = ValueMinimization.marker
        let stored = try transaction.query(
            """
            SELECT text_value FROM memory_operation_arguments
            WHERE event_id = ? AND argument_name = ? AND position = ? AND value_kind = 'text'
            """,
            [.text(redaction.eventID), .text(name), .integer(Int64(position))]
        ) { try $0.text(0) }.first
        guard let current = stored else {
            throw OperationFactError.missingArgument(eventID: redaction.eventID, name: name, position: position)
        }
        var receipt = MemoryReceipt.alreadyApplied
        if current != marker {
            try transaction.execute(
                """
                UPDATE memory_operation_arguments SET text_value = ?
                WHERE event_id = ? AND argument_name = ? AND position = ?
                """,
                [.text(marker), .text(redaction.eventID), .text(name), .integer(Int64(position))]
            )
            receipt = .committed
        }
        return try record(transaction, redaction) == .committed ? .committed : receipt
    }

    static func redactions(_ handle: some SQLiteQuerying, _ eventID: String) throws -> [ValueRedaction] {
        try handle.query(
            """
            SELECT location_kind, argument_name, argument_position, condition_kind, sample_phase, sample_ordinal,
                   element_position, reason
            FROM memory_value_redactions WHERE event_id = ? ORDER BY redaction_id
            """,
            [.text(eventID)]
        ) { row in
            let kind = try row.text(0) ?? "", reasonCode = try row.text(7) ?? ""
            guard let reason = WithholdingReason(rawValue: reasonCode) else {
                throw malformed("memory_value_redactions", eventID, "reason")
            }
            let location: ValueRedaction.Location
            switch kind {
                case "argument":
                    location = .argument(name: try row.text(1) ?? "", position: Int(row.integer(2) ?? 0))
                case "result_message":
                    location = .resultMessage
                case "verification_expected", "verification_observed":
                    guard let condition = OperationCheck.Condition(rawValue: try row.text(3) ?? "") else {
                        throw malformed("memory_value_redactions", eventID, "condition_kind")
                    }
                    location = kind == "verification_expected"
                        ? .verificationExpected(condition) : .verificationObserved(condition)
                case "target_label":
                    location = .targetLabel
                case "target_section":
                    location = .targetSection
                case "target_element":
                    location = .targetElement
                case "observed_effect":
                    location = .observedEffect
                case "listing_entry":
                    location = .listingEntry(application: Int(row.integer(6) ?? 0))
                case "sample_label", "sample_container":
                    guard let phase = CapturePhase(rawValue: try row.text(4) ?? "") else {
                        throw malformed("memory_value_redactions", eventID, "sample_phase")
                    }
                    let ordinal = Int(row.integer(5) ?? 0), element = Int(row.integer(6) ?? 0)
                    location = kind == "sample_label"
                        ? .sampleLabel(phase: phase, ordinal: ordinal, element: element)
                        : .sampleContainer(phase: phase, ordinal: ordinal, element: element)
                case "sample_title":
                    guard let phase = CapturePhase(rawValue: try row.text(4) ?? "") else {
                        throw malformed("memory_value_redactions", eventID, "sample_phase")
                    }
                    location = .sampleTitle(phase: phase, ordinal: Int(row.integer(5) ?? 0))
                default:
                    throw malformed("memory_value_redactions", eventID, "location_kind")
            }
            return ValueRedaction(eventID: eventID, location: location, reason: reason)
        }
    }

    /// The location's columns, in the table's order: kind, argument name and position, condition, sample
    /// phase, ordinal and element.
    private static func columns(_ location: ValueRedaction.Location) -> [SQLiteValue] {
        switch location {
            case .argument(let name, let position):
                [.text("argument"), .text(name), .integer(Int64(position)), .null, .null, .null, .null]
            case .resultMessage:
                [.text("result_message"), .null, .null, .null, .null, .null, .null]
            case .verificationExpected(let condition):
                [.text("verification_expected"), .null, .null, .text(condition.rawValue), .null, .null, .null]
            case .verificationObserved(let condition):
                [.text("verification_observed"), .null, .null, .text(condition.rawValue), .null, .null, .null]
            case .targetLabel:
                [.text("target_label"), .null, .null, .null, .null, .null, .null]
            case .targetSection:
                [.text("target_section"), .null, .null, .null, .null, .null, .null]
            case .targetElement:
                [.text("target_element"), .null, .null, .null, .null, .null, .null]
            case .sampleLabel(let phase, let ordinal, let element):
                [.text("sample_label"), .null, .null, .null, .text(phase.rawValue), .integer(Int64(ordinal)),
                 .integer(Int64(element))]
            case .sampleContainer(let phase, let ordinal, let element):
                [.text("sample_container"), .null, .null, .null, .text(phase.rawValue), .integer(Int64(ordinal)),
                 .integer(Int64(element))]
            case .sampleTitle(let phase, let ordinal):
                [.text("sample_title"), .null, .null, .null, .text(phase.rawValue), .integer(Int64(ordinal)), .null]
            case .observedEffect:
                [.text("observed_effect"), .null, .null, .null, .null, .null, .null]
            case .listingEntry(let application):
                [.text("listing_entry"), .null, .null, .null, .null, .null, .integer(Int64(application))]
        }
    }

    // MARK: Helpers

    private static func text(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }

    private static func target(_ target: OperationCheck.Target?) -> [SQLiteValue] {
        guard let target else { return [.null, .null, .null, .null] }
        return [.text(target.elementID), text(target.role), .text(target.label), text(target.section)]
    }

    private static func target(_ row: SQLiteStatement.Row, from column: Int) throws -> OperationCheck.Target? {
        guard let id = try row.text(column), let label = try row.text(column + 2) else { return nil }
        return OperationCheck.Target(
            elementID: id,
            role: try row.text(column + 1),
            label: label,
            section: try row.text(column + 3)
        )
    }

    private static func malformed(_ table: String, _ id: String, _ column: String) -> EventFactError {
        .malformedRow(table: table, id: id, malformation: .unknownCode(column: column, code: "?"))
    }
}

/// OperationFactContract is the version of the operation facts' stored form: version 1 is schema 2's
/// effects, verifications, limits, samples and gaps.
public enum OperationFactContract {
    public static let version = 1
}

//
//  SQLiteTaskRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory

/// SQLiteVerificationRepository is `VerificationStoring` over `SQLiteMemoryStore`: a verification's
/// event through the events' codec and its facts in `memory_verifications`, in one transaction, with
/// `step_occurrence_id` NULL; the attribution to a step occurrence is a separate write, and the
/// schema's triggers keep it agreeing with a `verification` membership of that step.
public struct SQLiteVerificationRepository: VerificationStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ verification: VerificationRecord) async throws -> MemoryReceipt {
        try await store.write { transaction in
            _ = try SQLiteEventRows.record(transaction, verification.event)
            let eventID = verification.event.eventID
            if let stored = try SQLiteTaskRows.verification(transaction, eventID: eventID) {
                guard stored.record.isExactly(verification) else {
                    throw SQLiteFactRows.conflict(eventID, stored: "\(stored.record)", offered: "\(verification)")
                }
                return .alreadyApplied
            }
            try transaction.execute(
                "INSERT INTO memory_verifications (event_id, scope, method, verdict, expected_text, observed_text) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(eventID), .text(verification.scope.rawValue), .text(verification.method.rawValue), .text(verification.verdict.rawValue),
                 verification.expectedText.map(SQLiteValue.text) ?? .null, verification.observedText.map(SQLiteValue.text) ?? .null]
            )
            return .committed
        }
    }

    public func attribute(verification eventID: String, toStepOccurrence stepOccurrenceID: String) async throws -> MemoryReceipt {
        try await store.write { transaction in
            guard let stored = try SQLiteTaskRows.verification(transaction, eventID: eventID) else {
                throw EventFactError.missingEvent(eventID: eventID)
            }
            guard try SQLiteFactRows.exists(transaction, "SELECT count(*) FROM memory_step_occurrences WHERE step_occurrence_id = ?",
                                            stepOccurrenceID) else {
                throw EventFactError.missingOccurrence(id: stepOccurrenceID)
            }
            if let current = stored.stepOccurrenceID {
                guard current.utf8.elementsEqual(stepOccurrenceID.utf8) else { throw EventFactError.alreadyAttributed(eventID: eventID) }
                return .alreadyApplied
            }
            try transaction.execute("UPDATE memory_verifications SET step_occurrence_id = ? WHERE event_id = ?",
                                    [.text(stepOccurrenceID), .text(eventID)])
            return .committed
        }
    }

    public func verification(_ eventID: String) async throws -> StoredVerification? {
        try await store.read { snapshot in try SQLiteTaskRows.verification(snapshot, eventID: eventID) }
    }
}

/// SQLiteTaskRepository is `TaskAttributionStoring` over `SQLiteMemoryStore`: episodes in
/// `memory_task_occurrences`, memberships in `memory_task_events`, labels in `memory_task_labels`.
/// It writes what the caller states and never touches the events, the samples or the brain.
public struct SQLiteTaskRepository: TaskAttributionStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ occurrence: TaskOccurrenceRecord) async throws -> MemoryReceipt {
        try await store.write { transaction in try SQLiteTaskRows.record(transaction, occurrence) }
    }

    public func update(from expected: TaskOccurrenceRecord, to updated: TaskOccurrenceRecord) async throws -> MemoryReceipt {
        let id = expected.taskOccurrenceID
        guard expected.sameIdentity(as: updated) else {
            let field = !id.utf8.elementsEqual(updated.taskOccurrenceID.utf8) ? "task_occurrence_id"
                : expected.startedAtMS != updated.startedAtMS ? "started_at_ms" : "trace_id"
            throw EventFactError.immutableField(id: id, field: field)
        }
        return try await store.write { transaction in
            guard let stored = try SQLiteTaskRows.occurrence(transaction, id: id) else { throw EventFactError.missingOccurrence(id: id) }
            if stored.isExactly(updated) { return .alreadyApplied }
            guard stored.isExactly(expected) else { throw EventFactError.staleExpectation(id: id) }
            try transaction.execute("UPDATE memory_task_occurrences SET ended_at_ms = ?, status = ? WHERE task_occurrence_id = ?",
                                    [updated.endedAtMS.map(SQLiteValue.integer) ?? .null, .text(updated.status.rawValue), .text(id)])
            return .committed
        }
    }

    public func record(_ membership: TaskMembership) async throws -> MemoryReceipt {
        try await store.write { transaction in try SQLiteTaskRows.record(transaction, membership) }
    }

    public func record(_ label: TaskLabelRecord) async throws -> MemoryReceipt {
        try await store.write { transaction in try SQLiteTaskRows.record(transaction, label) }
    }

    public func attribute(_ attribution: TaskAttribution) async throws -> MemoryReceipt {
        try await store.write { transaction in
            var receipts = [try SQLiteTaskRows.record(transaction, attribution.occurrence)]
            for membership in attribution.memberships { receipts.append(try SQLiteTaskRows.record(transaction, membership)) }
            for label in attribution.labels { receipts.append(try SQLiteTaskRows.record(transaction, label)) }
            return receipts.contains(.committed) ? .committed : .alreadyApplied
        }
    }

    public func occurrence(_ taskOccurrenceID: String) async throws -> TaskOccurrenceRecord? {
        try await store.read { snapshot in try SQLiteTaskRows.occurrence(snapshot, id: taskOccurrenceID) }
    }

    public func memberships(of taskOccurrenceID: String) async throws -> [TaskMembership] {
        try await store.read { snapshot in try SQLiteTaskRows.memberships(snapshot, of: taskOccurrenceID) }
    }

    public func labels(of taskOccurrenceID: String) async throws -> [TaskLabelRecord] {
        try await store.read { snapshot in try SQLiteTaskRows.labels(snapshot, of: taskOccurrenceID) }
    }
}

/// SQLiteTaskRows is the codec of verifications, episodes, memberships and labels, each written
/// once by its key: the same content again is `alreadyApplied`, other content a conflict.
enum SQLiteTaskRows {

    // MARK: Verifications

    static func verification(_ handle: some SQLiteQuerying, eventID: String) throws -> StoredVerification? {
        func refuse(_ malformation: EventFactError.Malformation) -> EventFactError {
            .malformedRow(table: "memory_verifications", id: eventID, malformation: malformation)
        }
        guard let row = try handle.query(
            "SELECT scope, method, verdict, expected_text, observed_text, step_occurrence_id FROM memory_verifications WHERE event_id = ?",
            [.text(eventID)],
            { (scope: try $0.text(0) ?? "", method: try $0.text(1) ?? "", verdict: try $0.text(2) ?? "", expected: try $0.text(3),
               observed: try $0.text(4), step: try $0.text(5)) }
        ).first,
              let event = try SQLiteEventRows.read(handle, eventID: eventID) else { return nil }
        guard let scope = code(VerificationScope.self, row.scope) else { throw refuse(.unknownCode(column: "scope", code: row.scope)) }
        guard let method = code(VerificationMethod.self, row.method) else { throw refuse(.unknownCode(column: "method", code: row.method)) }
        guard let verdict = code(VerificationVerdict.self, row.verdict) else { throw refuse(.unknownCode(column: "verdict", code: row.verdict)) }
        do {
            let record = try VerificationRecord(event: event, scope: scope, method: method, verdict: verdict,
                                                expectedText: row.expected, observedText: row.observed)
            return StoredVerification(record: record, stepOccurrenceID: row.step)
        } catch EventFactError.invalidRecord(let invalidity) {
            throw refuse(.invalid(invalidity))
        }
    }

    // MARK: Episodes

    static func record(_ transaction: SQLiteTransaction, _ occurrence: TaskOccurrenceRecord) throws -> MemoryReceipt {
        let id = occurrence.taskOccurrenceID
        if let stored = try self.occurrence(transaction, id: id) {
            guard stored.isExactly(occurrence) else { throw SQLiteFactRows.conflict(id, stored: "\(stored)", offered: "\(occurrence)") }
            return .alreadyApplied
        }
        try transaction.execute(
            "INSERT INTO memory_task_occurrences (task_occurrence_id, trace_id, started_at_ms, ended_at_ms, status) VALUES (?, ?, ?, ?, ?)",
            [.text(id), occurrence.traceID.map(SQLiteValue.text) ?? .null, .integer(occurrence.startedAtMS),
             occurrence.endedAtMS.map(SQLiteValue.integer) ?? .null, .text(occurrence.status.rawValue)]
        )
        return .committed
    }

    static func occurrence(_ handle: some SQLiteQuerying, id: String) throws -> TaskOccurrenceRecord? {
        func refuse(_ malformation: EventFactError.Malformation) -> EventFactError {
            .malformedRow(table: "memory_task_occurrences", id: id, malformation: malformation)
        }
        return try handle.query(
            "SELECT task_occurrence_id, trace_id, started_at_ms, ended_at_ms, status FROM memory_task_occurrences WHERE task_occurrence_id = ?",
            [.text(id)]
        ) { row in
            let statusCode = try row.text(4) ?? ""
            guard let status = code(TaskStatus.self, statusCode) else { throw refuse(.unknownCode(column: "status", code: statusCode)) }
            do {
                return try TaskOccurrenceRecord(taskOccurrenceID: try row.text(0) ?? "", traceID: try row.text(1),
                                                startedAtMS: row.integer(2) ?? 0, endedAtMS: row.integer(3), status: status)
            } catch EventFactError.invalidRecord(let invalidity) {
                throw refuse(.invalid(invalidity))
            }
        }.first
    }

    // MARK: Memberships

    static func record(_ transaction: SQLiteTransaction, _ membership: TaskMembership) throws -> MemoryReceipt {
        let task = membership.taskOccurrenceID
        guard try occurrence(transaction, id: task) != nil else { throw EventFactError.missingOccurrence(id: task) }
        guard try SQLiteFactRows.exists(transaction, "SELECT count(*) FROM memory_events WHERE event_id = ?", membership.eventID) else {
            throw EventFactError.missingEvent(eventID: membership.eventID)
        }
        let stored = try memberships(transaction, of: task)
        if let same = stored.first(where: { $0.eventID.utf8.elementsEqual(membership.eventID.utf8) && $0.role == membership.role }) {
            guard same.position == membership.position else {
                throw SQLiteFactRows.conflict("\(task):\(membership.eventID):\(membership.role.rawValue)", stored: "\(same)", offered: "\(membership)")
            }
            return .alreadyApplied
        }
        if stored.contains(where: { $0.position == membership.position }) {
            throw EventFactError.positionTaken(taskOccurrenceID: task, position: membership.position)
        }
        try transaction.execute("INSERT INTO memory_task_events (task_occurrence_id, event_id, position, role) VALUES (?, ?, ?, ?)",
                                [.text(task), .text(membership.eventID), .integer(membership.position), .text(membership.role.rawValue)])
        return .committed
    }

    static func memberships(_ handle: some SQLiteQuerying, of task: String) throws -> [TaskMembership] {
        try handle.query(
            "SELECT event_id, position, role FROM memory_task_events WHERE task_occurrence_id = ? ORDER BY position",
            [.text(task)]
        ) { row in
            let eventID = try row.text(0) ?? "", roleCode = try row.text(2) ?? ""
            guard let role = code(TaskEventRole.self, roleCode) else {
                throw EventFactError.malformedRow(table: "memory_task_events", id: eventID, malformation: .unknownCode(column: "role", code: roleCode))
            }
            do {
                return try TaskMembership(taskOccurrenceID: task, eventID: eventID, position: row.integer(1) ?? -1, role: role)
            } catch EventFactError.invalidRecord(let invalidity) {
                throw EventFactError.malformedRow(table: "memory_task_events", id: eventID, malformation: .invalid(invalidity))
            }
        }
    }

    // MARK: Labels

    static func record(_ transaction: SQLiteTransaction, _ label: TaskLabelRecord) throws -> MemoryReceipt {
        guard try occurrence(transaction, id: label.taskOccurrenceID) != nil else {
            throw EventFactError.missingOccurrence(id: label.taskOccurrenceID)
        }
        if let stored = try self.label(transaction, id: label.labelID) {
            guard stored.isExactly(label) else { throw SQLiteFactRows.conflict(label.labelID, stored: "\(stored)", offered: "\(label)") }
            return .alreadyApplied
        }
        try transaction.execute(
            """
            INSERT INTO memory_task_labels (label_id, task_occurrence_id, label, assigned_by, confidence, status, assigned_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(label.labelID), .text(label.taskOccurrenceID), .text(label.label), .text(label.assignedBy),
             label.confidence.map(SQLiteValue.real) ?? .null, .text(label.status.rawValue), .integer(label.assignedAtMS)]
        )
        return .committed
    }

    private static let labelColumns = "label_id, task_occurrence_id, label, assigned_by, confidence, status, assigned_at_ms"

    static func label(_ handle: some SQLiteQuerying, id: String) throws -> TaskLabelRecord? {
        try handle.query("SELECT \(labelColumns) FROM memory_task_labels WHERE label_id = ?", [.text(id)], decodeLabel).first
    }

    static func labels(_ handle: some SQLiteQuerying, of task: String) throws -> [TaskLabelRecord] {
        try handle.query("SELECT \(labelColumns) FROM memory_task_labels WHERE task_occurrence_id = ?", [.text(task)], decodeLabel)
            .sorted { lhs, rhs in
                lhs.assignedAtMS != rhs.assignedAtMS ? lhs.assignedAtMS < rhs.assignedAtMS
                    : Array(lhs.labelID.utf8).lexicographicallyPrecedes(Array(rhs.labelID.utf8))
            }
    }

    private static func decodeLabel(_ row: SQLiteStatement.Row) throws -> TaskLabelRecord {
        let id = try row.text(0) ?? "", statusCode = try row.text(5) ?? ""
        guard let status = code(TaskLabelStatus.self, statusCode) else {
            throw EventFactError.malformedRow(table: "memory_task_labels", id: id, malformation: .unknownCode(column: "status", code: statusCode))
        }
        do {
            return try TaskLabelRecord(labelID: id, taskOccurrenceID: try row.text(1) ?? "", label: try row.text(2) ?? "",
                                       assignedBy: try row.text(3) ?? "", confidence: row.real(4), status: status,
                                       assignedAtMS: row.integer(6) ?? 0)
        } catch EventFactError.invalidRecord(let invalidity) {
            throw EventFactError.malformedRow(table: "memory_task_labels", id: id, malformation: .invalid(invalidity))
        }
    }

    private static func code<T: RawRepresentable>(_ type: T.Type, _ raw: String) -> T? where T.RawValue == String {
        guard let value = T(rawValue: raw), value.rawValue.utf8.elementsEqual(raw.utf8) else { return nil }
        return value
    }
}

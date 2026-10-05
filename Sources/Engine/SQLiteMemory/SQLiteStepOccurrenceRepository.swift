//
//  SQLiteStepOccurrenceRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory

/// SQLiteStepOccurrenceRepository is `StepOccurrenceStoring` over `SQLiteMemoryStore`: occurrences in
/// `memory_step_occurrences`, their memberships in `memory_step_events`, evidence in
/// `memory_route_evidence` and `memory_step_evidence`. Every write is one transaction, and the
/// verification's attribution and its membership are written in the same one.
public struct SQLiteStepOccurrenceRepository: StepOccurrenceStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ occurrence: StepOccurrenceRecord) async throws -> MemoryReceipt {
        try await store.write { transaction in
            let id = occurrence.stepOccurrenceID
            if let stored = try SQLiteStepRows.occurrence(transaction, id: id) {
                guard stored.record.isExactly(occurrence) else { throw SQLiteFactRows.conflict(id, stored: "\(stored.record)", offered: "\(occurrence)") }
                return .alreadyApplied
            }
            try transaction.execute(
                "INSERT INTO memory_step_occurrences (step_occurrence_id, started_at_ms, ended_at_ms, status) VALUES (?, ?, ?, ?)",
                [.text(id), .integer(occurrence.startedAtMS), occurrence.endedAtMS.map(SQLiteValue.integer) ?? .null, .text(occurrence.status.rawValue)]
            )
            return .committed
        }
    }

    public func update(from expected: StepOccurrenceRecord, to updated: StepOccurrenceRecord) async throws -> MemoryReceipt {
        let id = expected.stepOccurrenceID
        guard id.utf8.elementsEqual(updated.stepOccurrenceID.utf8) else { throw EventFactError.immutableField(id: id, field: "step_occurrence_id") }
        guard expected.startedAtMS == updated.startedAtMS else { throw EventFactError.immutableField(id: id, field: "started_at_ms") }
        return try await store.write { transaction in
            guard let stored = try SQLiteStepRows.occurrence(transaction, id: id) else { throw EventFactError.missingOccurrence(id: id) }
            if stored.record.isExactly(updated) { return .alreadyApplied }
            guard stored.record.isExactly(expected) else { throw EventFactError.staleExpectation(id: id) }
            try transaction.execute("UPDATE memory_step_occurrences SET ended_at_ms = ?, status = ? WHERE step_occurrence_id = ?",
                                    [updated.endedAtMS.map(SQLiteValue.integer) ?? .null, .text(updated.status.rawValue), .text(id)])
            return .committed
        }
    }

    public func assign(_ stepOccurrenceID: String, toTask taskOccurrenceID: String?, step stepID: String?, by author: String) async throws -> MemoryReceipt {
        guard !author.isEmpty else { throw EventFactError.invalidRecord(.emptyText(field: "assigned_by")) }
        return try await store.write { transaction in
            guard let stored = try SQLiteStepRows.occurrence(transaction, id: stepOccurrenceID) else {
                throw EventFactError.missingOccurrence(id: stepOccurrenceID)
            }
            if let task = taskOccurrenceID, try SQLiteTaskRows.occurrence(transaction, id: task) == nil { throw EventFactError.missingOccurrence(id: task) }
            if let step = stepID, !(try SQLiteFactRows.exists(transaction, "SELECT count(*) FROM memory_route_steps WHERE step_id = ?", step)) {
                throw EventFactError.missingDefinition(id: step)
            }
            var changed = false
            for (offered, current) in [(taskOccurrenceID, stored.taskOccurrenceID), (stepID, stored.stepID)] {
                guard let offered else { continue }
                if let current {
                    guard current.utf8.elementsEqual(offered.utf8) else { throw EventFactError.alreadyAssigned(id: stepOccurrenceID) }
                } else {
                    changed = true
                }
            }
            if let by = stored.assignedBy, !by.utf8.elementsEqual(author.utf8) { throw EventFactError.alreadyAssigned(id: stepOccurrenceID) }
            guard changed else { return .alreadyApplied }
            try transaction.execute(
                """
                UPDATE memory_step_occurrences SET task_occurrence_id = coalesce(task_occurrence_id, ?), step_id = coalesce(step_id, ?),
                    assigned_by = ? WHERE step_occurrence_id = ?
                """,
                [taskOccurrenceID.map(SQLiteValue.text) ?? .null, stepID.map(SQLiteValue.text) ?? .null, .text(author), .text(stepOccurrenceID)]
            )
            return .committed
        }
    }

    public func record(_ membership: StepMembership) async throws -> MemoryReceipt {
        try await store.write { transaction in try SQLiteStepRows.record(transaction, membership) }
    }

    public func attribute(verification eventID: String, to membership: StepMembership) async throws -> MemoryReceipt {
        guard membership.role == .verification, membership.eventID.utf8.elementsEqual(eventID.utf8) else {
            throw EventFactError.invalidRecord(.shape(field: "role"))
        }
        return try await store.write { transaction in
            guard let stored = try SQLiteTaskRows.verification(transaction, eventID: eventID) else { throw EventFactError.missingEvent(eventID: eventID) }
            let target = membership.stepOccurrenceID
            guard try SQLiteStepRows.occurrence(transaction, id: target) != nil else { throw EventFactError.missingOccurrence(id: target) }
            var changed = false
            if let current = stored.stepOccurrenceID {
                guard current.utf8.elementsEqual(target.utf8) else { throw EventFactError.alreadyAttributed(eventID: eventID) }
            } else {
                try transaction.execute("UPDATE memory_verifications SET step_occurrence_id = ? WHERE event_id = ?", [.text(target), .text(eventID)])
                changed = true
            }
            let receipt = try SQLiteStepRows.record(transaction, membership)
            return changed || receipt == .committed ? .committed : .alreadyApplied
        }
    }

    public func record(_ evidence: DefinitionEvidence) async throws -> MemoryReceipt {
        try await store.write { transaction in
            switch evidence.subject {
                case .route(let routeID, let taskID):
                    guard try SQLiteRouteRows.status(transaction, routeID) != nil else { throw EventFactError.missingDefinition(id: routeID) }
                    guard try SQLiteTaskRows.occurrence(transaction, id: taskID) != nil else { throw EventFactError.missingOccurrence(id: taskID) }
                case .step(let stepID, let occurrenceID):
                    guard let occurrence = try SQLiteStepRows.occurrence(transaction, id: occurrenceID) else { throw EventFactError.missingOccurrence(id: occurrenceID) }
                    guard occurrence.stepID.map({ $0.utf8.elementsEqual(stepID.utf8) }) == true else {
                        throw EventFactError.occurrenceNotOfStep(stepOccurrenceID: occurrenceID, stepID: stepID)
                    }
            }
            let stored = try SQLiteStepRows.evidence(transaction, of: evidence.subject).first { $0.relation == evidence.relation && SQLiteStepRows.sameSubject($0, evidence) }
            if let stored {
                guard stored.isExactly(evidence) else { throw SQLiteFactRows.conflict("\(evidence.subject)", stored: "\(stored)", offered: "\(evidence)") }
                return .alreadyApplied
            }
            switch evidence.subject {
                case .route(let routeID, let taskID):
                    try transaction.execute(
                        "INSERT INTO memory_route_evidence (route_id, task_occurrence_id, relation, assessed_by, assessed_at_ms) VALUES (?, ?, ?, ?, ?)",
                        [.text(routeID), .text(taskID), .text(evidence.relation.rawValue), .text(evidence.assessedBy), .integer(evidence.assessedAtMS)])
                case .step(let stepID, let occurrenceID):
                    try transaction.execute(
                        "INSERT INTO memory_step_evidence (step_id, step_occurrence_id, relation, assessed_by, assessed_at_ms) VALUES (?, ?, ?, ?, ?)",
                        [.text(stepID), .text(occurrenceID), .text(evidence.relation.rawValue), .text(evidence.assessedBy), .integer(evidence.assessedAtMS)])
            }
            return .committed
        }
    }

    public func occurrence(_ stepOccurrenceID: String) async throws -> StoredStepOccurrence? {
        try await store.read { snapshot in try SQLiteStepRows.occurrence(snapshot, id: stepOccurrenceID) }
    }

    public func memberships(of stepOccurrenceID: String) async throws -> [StepMembership] {
        try await store.read { snapshot in try SQLiteStepRows.memberships(snapshot, of: stepOccurrenceID) }
    }

    public func evidence(ofRoute routeID: String) async throws -> [DefinitionEvidence] {
        try await store.read { snapshot in try SQLiteStepRows.evidence(snapshot, of: .route(routeID: routeID, taskOccurrenceID: "")) }
    }

    public func evidence(ofStep stepID: String) async throws -> [DefinitionEvidence] {
        try await store.read { snapshot in try SQLiteStepRows.evidence(snapshot, of: .step(stepID: stepID, stepOccurrenceID: "")) }
    }
}

/// SQLiteStepRows is the codec of step occurrences, their memberships and evidence.
enum SQLiteStepRows {

    static func occurrence(_ handle: some SQLiteQuerying, id: String) throws -> StoredStepOccurrence? {
        try handle.query(
            "SELECT started_at_ms, ended_at_ms, status, task_occurrence_id, step_id, assigned_by FROM memory_step_occurrences WHERE step_occurrence_id = ?",
            [.text(id)]
        ) { row in
            let statusCode = try row.text(2) ?? ""
            guard let status = SQLiteRouteRows.code(TaskStatus.self, statusCode) else {
                throw EventFactError.malformedRow(table: "memory_step_occurrences", id: id, malformation: .unknownCode(column: "status", code: statusCode))
            }
            do {
                let record = try StepOccurrenceRecord(stepOccurrenceID: id, startedAtMS: row.integer(0) ?? 0, endedAtMS: row.integer(1), status: status)
                let task = try row.text(3), step = try row.text(4), by = try row.text(5)
                if (task != nil || step != nil) != (by != nil) {
                    throw EventFactError.malformedRow(table: "memory_step_occurrences", id: id, malformation: .invalid(.shape(field: "assigned_by")))
                }
                return StoredStepOccurrence(record: record, taskOccurrenceID: task, stepID: step, assignedBy: by)
            } catch EventFactError.invalidRecord(let invalidity) {
                throw EventFactError.malformedRow(table: "memory_step_occurrences", id: id, malformation: .invalid(invalidity))
            }
        }.first
    }

    static func record(_ transaction: SQLiteTransaction, _ membership: StepMembership) throws -> MemoryReceipt {
        let occurrenceID = membership.stepOccurrenceID
        guard try occurrence(transaction, id: occurrenceID) != nil else { throw EventFactError.missingOccurrence(id: occurrenceID) }
        guard try SQLiteFactRows.exists(transaction, "SELECT count(*) FROM memory_events WHERE event_id = ?", membership.eventID) else {
            throw EventFactError.missingEvent(eventID: membership.eventID)
        }
        if membership.role == .verification {
            let attributed = try SQLiteTaskRows.verification(transaction, eventID: membership.eventID)?.stepOccurrenceID
            guard attributed.map({ $0.utf8.elementsEqual(occurrenceID.utf8) }) == true else {
                throw EventFactError.wrongEvent(eventID: membership.eventID, expected: "a verification attributed to this occurrence")
            }
        }
        let stored = try memberships(transaction, of: occurrenceID)
        if let same = stored.first(where: { $0.eventID.utf8.elementsEqual(membership.eventID.utf8) && $0.role == membership.role }) {
            guard same.isExactly(membership) else {
                throw SQLiteFactRows.conflict("\(occurrenceID):\(membership.eventID):\(membership.role.rawValue)", stored: "\(same)", offered: "\(membership)")
            }
            return .alreadyApplied
        }
        if stored.contains(where: { $0.position == membership.position }) {
            throw EventFactError.positionTaken(taskOccurrenceID: occurrenceID, position: membership.position)
        }
        try transaction.execute(
            "INSERT INTO memory_step_events (step_occurrence_id, event_id, position, attempt_number, role) VALUES (?, ?, ?, ?, ?)",
            [.text(occurrenceID), .text(membership.eventID), .integer(membership.position), membership.attemptNumber.map(SQLiteValue.integer) ?? .null,
             .text(membership.role.rawValue)]
        )
        return .committed
    }

    static func memberships(_ handle: some SQLiteQuerying, of occurrenceID: String) throws -> [StepMembership] {
        try handle.query(
            "SELECT event_id, position, attempt_number, role FROM memory_step_events WHERE step_occurrence_id = ? ORDER BY position",
            [.text(occurrenceID)]
        ) { row in
            let eventID = try row.text(0) ?? "", roleCode = try row.text(3) ?? ""
            guard let role = SQLiteRouteRows.code(TaskEventRole.self, roleCode) else {
                throw EventFactError.malformedRow(table: "memory_step_events", id: eventID, malformation: .unknownCode(column: "role", code: roleCode))
            }
            do {
                return try StepMembership(stepOccurrenceID: occurrenceID, eventID: eventID, position: row.integer(1) ?? -1,
                                          attemptNumber: row.integer(2), role: role)
            } catch EventFactError.invalidRecord(let invalidity) {
                throw EventFactError.malformedRow(table: "memory_step_events", id: eventID, malformation: .invalid(invalidity))
            }
        }
    }

    /// The evidence of a Route or a step, by its key's other parts and relation, as bytes.
    static func evidence(_ handle: some SQLiteQuerying, of subject: DefinitionEvidence.Subject) throws -> [DefinitionEvidence] {
        let (sql, id, table): (String, String, String)
        switch subject {
            case .route(let routeID, _):
                (sql, id, table) = ("SELECT task_occurrence_id, relation, assessed_by, assessed_at_ms FROM memory_route_evidence WHERE route_id = ?", routeID, "memory_route_evidence")
            case .step(let stepID, _):
                (sql, id, table) = ("SELECT step_occurrence_id, relation, assessed_by, assessed_at_ms FROM memory_step_evidence WHERE step_id = ?", stepID, "memory_step_evidence")
        }
        let rows = try handle.query(sql, [.text(id)]) { row -> DefinitionEvidence in
            let other = try row.text(0) ?? "", relationCode = try row.text(1) ?? ""
            guard let relation = SQLiteRouteRows.code(EvidenceRelation.self, relationCode) else {
                throw EventFactError.malformedRow(table: table, id: "\(id):\(other)", malformation: .unknownCode(column: "relation", code: relationCode))
            }
            let subject: DefinitionEvidence.Subject = switch subject {
                case .route: .route(routeID: id, taskOccurrenceID: other)
                case .step : .step(stepID: id, stepOccurrenceID: other)
            }
            do {
                return try DefinitionEvidence(subject, relation: relation, assessedBy: try row.text(2) ?? "", assessedAtMS: row.integer(3) ?? 0)
            } catch EventFactError.invalidRecord(let invalidity) {
                throw EventFactError.malformedRow(table: table, id: "\(id):\(other)", malformation: .invalid(invalidity))
            }
        }
        return rows.sorted { lhs, rhs in
            func key(_ e: DefinitionEvidence) -> [UInt8] {
                switch e.subject { case .route(_, let b), .step(_, let b): Array(b.utf8) + [0] + Array(e.relation.rawValue.utf8) }
            }
            return key(lhs).lexicographicallyPrecedes(key(rhs))
        }
    }

    static func sameSubject(_ stored: DefinitionEvidence, _ offered: DefinitionEvidence) -> Bool {
        switch (stored.subject, offered.subject) {
            case (.route(let a, let b), .route(let c, let d)), (.step(let a, let b), .step(let c, let d)):
                a.utf8.elementsEqual(c.utf8) && b.utf8.elementsEqual(d.utf8)
            default:
                false
        }
    }
}

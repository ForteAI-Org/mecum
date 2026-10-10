//
//  SQLiteTaskContextRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation
import Memory

/// SQLiteTaskContextRepository is `TaskContextStoring` over `SQLiteMemoryStore`: tasks in `memory_tasks`,
/// their revisions with constraints, message references and inputs, their attempts as episodes of
/// `memory_task_occurrences` described by `memory_task_attempts`, and the checkpoints and ends with their
/// outputs. Every write is one transaction that checks, inside it, the producer that owns the task,
/// the revision the caller read and the attempt's state, so two writers never both move the same task.
public struct SQLiteTaskContextRepository: TaskContextStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func open(_ task: TaskRecord, revision: TaskRevision, attempt: TaskAttempt) async throws -> MemoryReceipt {
        func refuse(_ invalidity: TaskContextError.Invalidity) -> TaskContextError { .invalid(invalidity) }
        guard task.status == .open, task.currentRevision == 1, revision.revision == 1, attempt.ordinal == 1,
              revision.taskID.utf8.elementsEqual(task.taskID.utf8), attempt.taskID.utf8.elementsEqual(task.taskID.utf8),
              attempt.openedAtRevision == 1, attempt.producer.isExactly(task.producer) else {
            throw refuse(.revisionChangeMismatch)
        }
        return try await store.write { transaction in
            if let stored = try SQLiteTaskContextRows.task(transaction, task.taskID) {
                let sameRevision = try SQLiteTaskContextRows.revision(transaction, task.taskID, 1).map {
                    $0.isExactly(revision)
                } ?? false
                let sameAttempt  = try SQLiteTaskContextRows.attempt(transaction, attempt.attemptID).map {
                    SQLiteTaskContextRows.same($0.attempt, attempt)
                } ?? false
                guard SQLiteTaskContextRows.sameOpening(stored, task), sameRevision, sameAttempt else {
                    throw SQLiteFactRows.conflict(task.taskID, stored: "task", offered: "another opening")
                }
                return .alreadyApplied
            }
            try SQLiteTaskContextRows.insert(transaction, task)
            try SQLiteTaskContextRows.insert(transaction, revision)
            try SQLiteTaskContextRows.insert(transaction, attempt, traceID: task.traceID)
            return .committed
        }
    }

    public func revise(
        _ revision       : TaskRevision,
        expecting current: Int,
        by producer      : TaskProducer
    ) async throws -> MemoryReceipt {
        try await store.write { transaction in
            let task = try SQLiteTaskContextRows.owned(transaction, revision.taskID, by: producer)
            if let stored = try SQLiteTaskContextRows.revision(transaction, revision.taskID, revision.revision) {
                guard stored.isExactly(revision) else {
                    throw TaskContextError.staleRevision(
                        taskID: task.taskID,
                        expected: current,
                        current: task.currentRevision
                    )
                }
                return .alreadyApplied
            }
            if task.status.isClosed { throw TaskContextError.closed(taskID: task.taskID, status: task.status) }
            // Subtracting from a validated revision (at least 1) cannot overflow; adding to `current` could.
            guard task.currentRevision == current, revision.revision - 1 == current else {
                throw TaskContextError.staleRevision(
                    taskID: task.taskID,
                    expected: current,
                    current: task.currentRevision
                )
            }
            try SQLiteTaskContextRows.insert(transaction, revision)
            try transaction.execute("UPDATE memory_tasks SET current_revision = ? WHERE task_id = ?",
                                    [.integer(Int64(revision.revision)), .text(task.taskID)])
            return .committed
        }
    }

    public func checkpoint(
        _ draft      : TaskCheckpointDraft,
        attempt      : String,
        at recordedAtMS: Int64,
        by producer  : TaskProducer
    ) async throws -> (receipt: MemoryReceipt, checkpoint: TaskCheckpoint) {
        try await store.write { transaction in
            guard let stored = try SQLiteTaskContextRows.attempt(transaction, attempt) else {
                throw TaskContextError.unknownAttempt(attemptID: attempt)
            }
            let task = try SQLiteTaskContextRows.owned(transaction, stored.attempt.taskID, by: producer)
            let earlier = try SQLiteTaskContextRows.checkpoints(transaction, of: attempt)
            // A retried call declares what the last checkpoint already declared at the same revision: nothing is added.
            if let last = earlier.last, last.declaresSame(as: draft, at: task.currentRevision) {
                return (MemoryReceipt.alreadyApplied, last)
            }
            if task.status.isClosed { throw TaskContextError.closed(taskID: task.taskID, status: task.status) }
            guard stored.status == .inProgress else { throw TaskContextError.attemptNotRunning(attemptID: attempt) }
            let checkpoint = try TaskCheckpoint(
                attemptID   : attempt,
                sequence    : try TaskContextContract.successor(of: earlier.last?.sequence ?? 0, field: "sequence"),
                kind        : draft.kind,
                revision    : task.currentRevision,
                recordedAtMS: max(recordedAtMS, stored.attempt.openedAtMS),
                declared    : draft.declared,
                note        : draft.note,
                outputs     : draft.outputs
            )
            try SQLiteTaskContextRows.insert(transaction, checkpoint, taskID: task.taskID)
            if checkpoint.kind == .end, let declared = checkpoint.declared {
                let episode: TaskStatus = switch declared {
                    case .completed: .completed
                    case .failed   : .failed
                    case .abandoned, .open: .cancelled
                }
                try transaction.execute(
                    "UPDATE memory_task_occurrences SET status = ?, ended_at_ms = ? WHERE task_occurrence_id = ?",
                    [.text(episode.rawValue), .integer(checkpoint.recordedAtMS), .text(attempt)]
                )
                try transaction.execute(
                    "UPDATE memory_tasks SET status = ?, closed_at_ms = ? WHERE task_id = ?",
                    [.text(declared.rawValue), .integer(max(checkpoint.recordedAtMS, task.openedAtMS)),
                     .text(task.taskID)]
                )
            }
            return (MemoryReceipt.committed, checkpoint)
        }
    }

    public func resume(_ attempt: TaskAttempt) async throws -> MemoryReceipt {
        try await store.write { transaction in
            if let stored = try SQLiteTaskContextRows.attempt(transaction, attempt.attemptID) {
                guard SQLiteTaskContextRows.same(stored.attempt, attempt) else {
                    throw SQLiteFactRows.conflict(attempt.attemptID, stored: "attempt", offered: "another attempt")
                }
                return .alreadyApplied
            }
            let task = try SQLiteTaskContextRows.owned(transaction, attempt.taskID, by: attempt.producer)
            if task.status.isClosed { throw TaskContextError.closed(taskID: task.taskID, status: task.status) }
            let attempts = try SQLiteTaskContextRows.attempts(transaction, of: task.taskID)
            guard let last = attempts.last, let resumed = attempt.resumes,
                  last.attempt.attemptID.utf8.elementsEqual(resumed.utf8),
                  attempt.ordinal - 1 == last.attempt.ordinal else {
                throw TaskContextError.unknownAttempt(attemptID: attempt.resumes ?? attempt.attemptID)
            }
            guard attempt.openedAtRevision == task.currentRevision else {
                throw TaskContextError.staleRevision(
                    taskID: task.taskID,
                    expected: attempt.openedAtRevision,
                    current: task.currentRevision
                )
            }
            if last.status == .inProgress {
                try transaction.execute(
                    """
                    UPDATE memory_task_occurrences SET status = 'interrupted', ended_at_ms = ?
                    WHERE task_occurrence_id = ?
                    """,
                    [.integer(max(attempt.openedAtMS, last.attempt.openedAtMS)), .text(last.attempt.attemptID)]
                )
            }
            try SQLiteTaskContextRows.insert(transaction, attempt, traceID: task.traceID)
            return .committed
        }
    }

    public func task(_ taskID: String, for producer: TaskProducer) async throws -> TaskRecord? {
        try await store.read { snapshot in
            guard let task = try SQLiteTaskContextRows.task(snapshot, taskID) else { return nil }
            guard task.producer.isExactly(producer) else { throw TaskContextError.foreignTask(taskID: taskID) }
            return task
        }
    }

    public func revision(_ revision: Int, of taskID: String, for producer: TaskProducer) async throws -> TaskRevision? {
        try await store.read { snapshot in
            guard try SQLiteTaskContextRows.task(snapshot, taskID) != nil else { return nil }
            _ = try SQLiteTaskContextRows.owned(snapshot, taskID, by: producer)
            return try SQLiteTaskContextRows.revision(snapshot, taskID, revision)
        }
    }

    public func attempts(of taskID: String, for producer: TaskProducer) async throws -> [StoredTaskAttempt] {
        try await store.read { snapshot in
            guard try SQLiteTaskContextRows.task(snapshot, taskID) != nil else { return [] }
            _ = try SQLiteTaskContextRows.owned(snapshot, taskID, by: producer)
            return try SQLiteTaskContextRows.attempts(snapshot, of: taskID)
        }
    }

    public func checkpoints(of attemptID: String, for producer: TaskProducer) async throws -> [TaskCheckpoint] {
        try await store.read { snapshot in
            guard let stored = try SQLiteTaskContextRows.attempt(snapshot, attemptID) else { return [] }
            _ = try SQLiteTaskContextRows.owned(snapshot, stored.attempt.taskID, by: producer)
            return try SQLiteTaskContextRows.checkpoints(snapshot, of: attemptID)
        }
    }

    public func calls(of attemptID: String, for producer: TaskProducer) async throws -> [String] {
        try await store.read { snapshot in
            guard let stored = try SQLiteTaskContextRows.attempt(snapshot, attemptID) else { return [] }
            _ = try SQLiteTaskContextRows.owned(snapshot, stored.attempt.taskID, by: producer)
            return try snapshot.query(
                """
                SELECT event_id FROM memory_task_events
                WHERE task_occurrence_id = ? AND role IN ('action', 'context') ORDER BY position
                """,
                [.text(attemptID)]
            ) { try $0.text(0) ?? "" }
        }
    }
}

/// SQLiteTaskContextRows is the codec of tasks, revisions, attempts and checkpoints, inside the
/// caller's transaction or snapshot.
enum SQLiteTaskContextRows {

    // MARK: Tasks

    static func insert(_ transaction: SQLiteTransaction, _ task: TaskRecord) throws {
        try transaction.execute(
            """
            INSERT INTO memory_tasks (task_id, contract_version, source, source_stream_id, trace_id, opened_at_ms,
                                      status, closed_at_ms, current_revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(task.taskID), .integer(Int64(task.contractVersion)), .text(task.producer.source.rawValue),
             .text(task.producer.streamID), task.traceID.map(SQLiteValue.text) ?? .null, .integer(task.openedAtMS),
             .text(task.status.rawValue), task.closedAtMS.map(SQLiteValue.integer) ?? .null,
             .integer(Int64(task.currentRevision))]
        )
    }

    static func task(_ handle: some SQLiteQuerying, _ taskID: String) throws -> TaskRecord? {
        try handle.query(
            """
            SELECT task_id, contract_version, source, source_stream_id, trace_id, opened_at_ms, status, closed_at_ms,
                   current_revision FROM memory_tasks WHERE task_id = ?
            """,
            [.text(taskID)]
        ) { row in
            let source = try row.text(2) ?? "", status = try row.text(6) ?? ""
            guard let producerSource = MemoryEventSource(rawValue: source),
                  let declared = DeclaredTaskStatus(rawValue: status) else {
                throw malformed("memory_tasks", taskID, "source or status")
            }
            return try TaskRecord(
                taskID: try row.text(0) ?? "",
                contractVersion: Int(row.integer(1) ?? 0),
                producer: try TaskProducer(source: producerSource, streamID: try row.text(3) ?? ""),
                traceID: try row.text(4),
                openedAtMS: row.integer(5) ?? 0,
                status: declared,
                closedAtMS: row.integer(7),
                currentRevision: Int(row.integer(8) ?? 0)
            )
        }.first
    }

    /// The task, which must exist and belong to the producer.
    static func owned(_ handle: some SQLiteQuerying, _ taskID: String, by producer: TaskProducer) throws -> TaskRecord {
        guard let task = try task(handle, taskID) else { throw TaskContextError.unknownTask(taskID: taskID) }
        guard task.producer.isExactly(producer) else { throw TaskContextError.foreignTask(taskID: taskID) }
        return task
    }

    static func sameOpening(_ stored: TaskRecord, _ offered: TaskRecord) -> Bool {
        stored.taskID.utf8.elementsEqual(offered.taskID.utf8) && stored.contractVersion == offered.contractVersion
            && stored.producer.isExactly(offered.producer) && TaskContextTextSame.same(stored.traceID, offered.traceID)
            && stored.openedAtMS == offered.openedAtMS
    }

    // MARK: Revisions

    static func insert(_ transaction: SQLiteTransaction, _ revision: TaskRevision) throws {
        let id = SQLiteValue.text(revision.taskID), number = SQLiteValue.integer(Int64(revision.revision))
        let content = revision.content
        try transaction.execute(
            """
            INSERT INTO memory_task_revisions (task_id, revision, recorded_at_ms, change_kind, reason, goal,
                                               requested_result)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [id, number, .integer(revision.recordedAtMS), .text(revision.change.rawValue),
             revision.reason.map(SQLiteValue.text) ?? .null, .text(content.goal),
             content.requestedResult.map(SQLiteValue.text) ?? .null]
        )
        for (position, constraint) in content.constraints.enumerated() {
            try transaction.execute(
                """
                INSERT INTO memory_task_constraints (task_id, revision, position, constraint_text)
                VALUES (?, ?, ?, ?)
                """,
                [id, number, .integer(Int64(position)), .text(constraint)]
            )
        }
        for (position, reference) in content.messageRefs.enumerated() {
            try transaction.execute(
                "INSERT INTO memory_task_message_refs (task_id, revision, position, message_ref) VALUES (?, ?, ?, ?)",
                [id, number, .integer(Int64(position)), .text(reference)]
            )
        }
        for (position, value) in content.inputs.enumerated() {
            try insert(transaction, value, taskID: revision.taskID, position: position,
                       owner: [("revision", number)])
        }
    }

    static func revision(_ handle: some SQLiteQuerying, _ taskID: String, _ number: Int) throws -> TaskRevision? {
        let id = SQLiteValue.text(taskID), revision = SQLiteValue.integer(Int64(number))
        guard let row = try handle.query(
            """
            SELECT recorded_at_ms, change_kind, reason, goal, requested_result FROM memory_task_revisions
            WHERE task_id = ? AND revision = ?
            """,
            [id, revision],
            { (at: $0.integer(0) ?? 0, change: try $0.text(1) ?? "", reason: try $0.text(2), goal: try $0.text(3) ?? "",
               result: try $0.text(4)) }
        ).first else { return nil }
        guard let change = TaskRevision.Change(rawValue: row.change) else {
            throw malformed("memory_task_revisions", taskID, "change_kind")
        }
        let constraints = try handle.query(
            "SELECT constraint_text FROM memory_task_constraints WHERE task_id = ? AND revision = ? ORDER BY position",
            [id, revision]
        ) { try $0.text(0) ?? "" }
        let references = try handle.query(
            "SELECT message_ref FROM memory_task_message_refs WHERE task_id = ? AND revision = ? ORDER BY position",
            [id, revision]
        ) { try $0.text(0) ?? "" }
        let inputs = try values(handle, "task_id = ? AND revision = ?", [id, revision], id: taskID)
        let content = try TaskRevisionContent(goal: row.goal, requestedResult: row.result, constraints: constraints,
                                              inputs: inputs, messageRefs: references)
        return try TaskRevision(
            taskID: taskID,
            revision: number,
            recordedAtMS: row.at,
            change: change,
            reason: row.reason,
            content: content
        )
    }

    // MARK: Values

    static func insert(_ transaction: SQLiteTransaction, _ value: TaskValue, taskID: String, position: Int,
                       owner: [(column: String, value: SQLiteValue)]) throws {
        let (content, text): (String, SQLiteValue) = switch value.content {
            case .text(let text): ("text", .text(text))
            case .missing       : ("missing", .null)
            case .withheld      : ("withheld", .null)
        }
        let columns = owner.map(\.column).joined(separator: ", ")
        let marks   = owner.map { _ in "?" }.joined(separator: ", ")
        // Column names are this codec's own literals; nothing from a caller is spliced in.
        try transaction.execute(
            """
            INSERT INTO memory_task_values (task_id, \(columns), position, name, role, value_kind, content, text_value,
                                            sensitivity, source, source_ref, source_version)
            VALUES (?, \(marks), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(taskID)] + owner.map(\.value)
                + [.integer(Int64(position)), .text(value.name), value.role.map(SQLiteValue.text) ?? .null,
                   .text(value.kind.rawValue), .text(content), text, .text(value.sensitivity.rawValue),
                   .text(value.source.rawValue), value.sourceRef.map(SQLiteValue.text) ?? .null,
                   value.sourceVersion.map(SQLiteValue.text) ?? .null]
        )
    }

    static func values(
        _ handle   : some SQLiteQuerying,
        _ condition: String,
        _ bindings : [SQLiteValue],
        id         : String
    ) throws -> [TaskValue] {
        // The condition is this codec's own literal; the bindings carry every value.
        try handle.query(
            """
            SELECT name, role, value_kind, content, text_value, sensitivity, source, source_ref, source_version
            FROM memory_task_values WHERE \(condition) ORDER BY position
            """,
            bindings
        ) { row in
            let kindCode = try row.text(2) ?? "", contentCode = try row.text(3) ?? "",
                sensitivityCode = try row.text(5) ?? ""
            let sourceCode = try row.text(6) ?? ""
            guard let kind = TaskValueKind(rawValue: kindCode),
                  let sensitivity = TaskValueSensitivity(rawValue: sensitivityCode),
                  let source = TaskValueSource(rawValue: sourceCode) else {
                throw malformed("memory_task_values", id, "kind, sensitivity or source")
            }
            let content: TaskValue.Content
            switch contentCode {
                case "text"    : content = .text(try row.text(4) ?? "")
                case "missing" : content = .missing
                case "withheld": content = .withheld
                default        : throw malformed("memory_task_values", id, "content")
            }
            return try TaskValue(
                name: try row.text(0) ?? "",
                role: try row.text(1),
                kind: kind,
                content: content,
                sensitivity: sensitivity,
                source: source,
                sourceRef: try row.text(7),
                sourceVersion: try row.text(8)
            )
        }
    }

    // MARK: Attempts

    static func insert(_ transaction: SQLiteTransaction, _ attempt: TaskAttempt, traceID: String?) throws {
        _ = try SQLiteTaskRows.record(transaction, try TaskOccurrenceRecord(
            taskOccurrenceID: attempt.attemptID, traceID: traceID, startedAtMS: attempt.openedAtMS, status: .inProgress
        ))
        try transaction.execute(
            """
            INSERT INTO memory_task_attempts (task_occurrence_id, task_id, ordinal, resumes_task_occurrence_id, source,
                                              source_stream_id, opened_at_ms, opened_at_revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(attempt.attemptID), .text(attempt.taskID), .integer(Int64(attempt.ordinal)),
             attempt.resumes.map(SQLiteValue.text) ?? .null, .text(attempt.producer.source.rawValue),
             .text(attempt.producer.streamID), .integer(attempt.openedAtMS), .integer(Int64(attempt.openedAtRevision))]
        )
    }

    private static let attemptColumns = """
        a.task_occurrence_id, a.task_id, a.ordinal, a.resumes_task_occurrence_id, a.source, a.source_stream_id,
        a.opened_at_ms, a.opened_at_revision, o.status, o.ended_at_ms
        """

    static func attempt(_ handle: some SQLiteQuerying, _ attemptID: String) throws -> StoredTaskAttempt? {
        try handle.query(
            """
            SELECT \(attemptColumns) FROM memory_task_attempts a
            JOIN memory_task_occurrences o ON o.task_occurrence_id = a.task_occurrence_id
            WHERE a.task_occurrence_id = ?
            """,
            [.text(attemptID)], decodeAttempt
        ).first
    }

    static func attempts(_ handle: some SQLiteQuerying, of taskID: String) throws -> [StoredTaskAttempt] {
        try handle.query(
            """
            SELECT \(attemptColumns) FROM memory_task_attempts a
            JOIN memory_task_occurrences o ON o.task_occurrence_id = a.task_occurrence_id
            WHERE a.task_id = ? ORDER BY a.ordinal
            """,
            [.text(taskID)], decodeAttempt
        )
    }

    private static func decodeAttempt(_ row: SQLiteStatement.Row) throws -> StoredTaskAttempt {
        let id = try row.text(0) ?? "", source = try row.text(4) ?? "", status = try row.text(8) ?? ""
        guard let producerSource = MemoryEventSource(rawValue: source),
              let episode = TaskStatus(rawValue: status) else {
            throw malformed("memory_task_attempts", id, "source or status")
        }
        let attempt = try TaskAttempt(
            attemptID: id, taskID: try row.text(1) ?? "", ordinal: Int(row.integer(2) ?? 0), resumes: try row.text(3),
            producer: try TaskProducer(source: producerSource, streamID: try row.text(5) ?? ""),
            openedAtMS: row.integer(6) ?? 0, openedAtRevision: Int(row.integer(7) ?? 0)
        )
        return StoredTaskAttempt(attempt: attempt, status: episode, endedAtMS: row.integer(9))
    }

    static func same(_ a: TaskAttempt, _ b: TaskAttempt) -> Bool {
        a.attemptID.utf8.elementsEqual(b.attemptID.utf8) && a.taskID.utf8.elementsEqual(b.taskID.utf8)
            && a.ordinal == b.ordinal && TaskContextTextSame.same(a.resumes, b.resumes)
            && a.producer.isExactly(b.producer) && a.openedAtMS == b.openedAtMS
            && a.openedAtRevision == b.openedAtRevision
    }

    // MARK: Checkpoints

    static func insert(_ transaction: SQLiteTransaction, _ checkpoint: TaskCheckpoint, taskID: String) throws {
        let attempt = SQLiteValue.text(checkpoint.attemptID), sequence = SQLiteValue.integer(Int64(checkpoint.sequence))
        try transaction.execute(
            """
            INSERT INTO memory_task_checkpoints (task_occurrence_id, sequence, checkpoint_kind, task_id, revision,
                                                 recorded_at_ms, declared_status, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [attempt, sequence, .text(checkpoint.kind.rawValue), .text(taskID), .integer(Int64(checkpoint.revision)),
             .integer(checkpoint.recordedAtMS), checkpoint.declared.map { SQLiteValue.text($0.rawValue) } ?? .null,
             checkpoint.note.map(SQLiteValue.text) ?? .null]
        )
        for (position, value) in checkpoint.outputs.enumerated() {
            try insert(transaction, value, taskID: taskID, position: position,
                       owner: [("task_occurrence_id", attempt), ("checkpoint_sequence", sequence)])
        }
    }

    static func checkpoints(_ handle: some SQLiteQuerying, of attemptID: String) throws -> [TaskCheckpoint] {
        let rows = try handle.query(
            """
            SELECT sequence, checkpoint_kind, revision, recorded_at_ms, declared_status, note
            FROM memory_task_checkpoints WHERE task_occurrence_id = ? ORDER BY sequence
            """,
            [.text(attemptID)]
        ) { (sequence: Int($0.integer(0) ?? 0), kind: try $0.text(1) ?? "", revision: Int($0.integer(2) ?? 0),
             at: $0.integer(3) ?? 0, declared: try $0.text(4), note: try $0.text(5)) }
        return try rows.map { row in
            guard let kind = TaskCheckpoint.Kind(rawValue: row.kind) else {
                throw malformed("memory_task_checkpoints", attemptID, "kind")
            }
            let declared = try row.declared.map { code -> DeclaredTaskStatus in
                guard let status = DeclaredTaskStatus(rawValue: code) else {
                    throw malformed("memory_task_checkpoints", attemptID, "status")
                }
                return status
            }
            let outputs = try values(handle, "task_occurrence_id = ? AND checkpoint_sequence = ?",
                                     [.text(attemptID), .integer(Int64(row.sequence))], id: attemptID)
            return try TaskCheckpoint(attemptID: attemptID, sequence: row.sequence, kind: kind, revision: row.revision,
                                      recordedAtMS: row.at, declared: declared, note: row.note, outputs: outputs)
        }
    }

    private static func malformed(_ table: String, _ id: String, _ column: String) -> EventFactError {
        .malformedRow(table: table, id: id, malformation: .unknownCode(column: column, code: "?"))
    }
}

/// TaskContextTextSame compares optional texts byte for byte, NULL apart from empty.
enum TaskContextTextSame {
    static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
            case (nil, nil)       : true
            case (let a?, let b?) : a.utf8.elementsEqual(b.utf8)
            default               : false
        }
    }
}

//
//  TaskContextRepositoryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// TaskFixtures opens a store with the task, fact and call repositories on it and builds a task the way
/// the tool's producer does.
enum TaskFixtures {

    static let t0: Int64 = 1_760_000_000_000
    static let producer = try! TaskProducer(source: .app, streamID: "worker-1")
    static let other    = try! TaskProducer(source: .mcp, streamID: "mcp-client")

    struct Memory {
        let url: URL
        let store: SQLiteMemoryStore
        let tasks: SQLiteTaskContextRepository
        let facts: SQLiteOperationFactRepository
        let calls: SQLiteAgentCallRepository

        func count(_ sql: String) async throws -> Int64 {
            try await store.read { try $0.query(sql) { $0.integer(0) ?? -1 }.first ?? -1 }
        }
    }

    static func open() async throws -> Memory {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return Memory(
            url: url,
            store: store,
            tasks: SQLiteTaskContextRepository(store: store),
            facts: SQLiteOperationFactRepository(store: store),
            calls: SQLiteAgentCallRepository(store: store)
        )
    }

    static func content(
        _ goal: String = "Export foto_demo.png as foto_web.jpg",
        inputs: [TaskValue] = []
    ) throws -> TaskRevisionContent {
        try TaskRevisionContent(
            goal: goal,
            requestedResult: "a JPEG copy",
            constraints: ["same folder"],
            inputs: inputs,
            messageRefs: ["message-1"]
        )
    }

    static func value(_ name: String, _ text: String, source: TaskValueSource = .request) throws -> TaskValue {
        try TaskValue(name: name, role: "file name", kind: .text, content: .text(text), source: source)
    }

    /// Opens task `id` with attempt `attempt` at revision 1.
    @discardableResult
    static func begin(_ memory: Memory, _ id: String = "task-1", attempt: String = "attempt-1",
                      producer: TaskProducer = TaskFixtures.producer) async throws -> MemoryReceipt {
        let task = try TaskRecord(taskID: id, producer: producer, traceID: "message-1", openedAtMS: t0, status: .open,
                                  closedAtMS: nil, currentRevision: 1)
        let revision = try TaskRevision(taskID: id, revision: 1, recordedAtMS: t0, change: .opened,
                                        content: try content(inputs: [try value("input_file", "foto_demo.png")]))
        let first = try TaskAttempt(attemptID: attempt, taskID: id, ordinal: 1, resumes: nil, producer: producer,
                                    openedAtMS: t0, openedAtRevision: 1)
        return try await memory.tasks.open(task, revision: revision, attempt: first)
    }
}

@Suite("Tasks an agent communicates, stored with their revisions, attempts and checkpoints")
struct TaskContextRepositoryTests {

    @Test("a task opens with its revision and first attempt in progress; offered again it adds nothing")
    func openOnce() async throws {
        let memory = try await TaskFixtures.open()
        #expect(try await TaskFixtures.begin(memory) == .committed)
        #expect(try await TaskFixtures.begin(memory) == .alreadyApplied)
        let task = try #require(try await memory.tasks.task("task-1", for: TaskFixtures.producer))
        #expect(task.status == .open && task.currentRevision == 1 && task.traceID == "message-1")
        let revision = try #require(try await memory.tasks.revision(1, of: "task-1", for: TaskFixtures.producer))
        #expect(revision.content.goal.hasPrefix("Export") && revision.content.inputs.map(\.name) == ["input_file"])
        #expect(revision.content.constraints == ["same folder"] && revision.content.messageRefs == ["message-1"])
        let attempts = try await memory.tasks.attempts(of: "task-1", for: TaskFixtures.producer)
        #expect(attempts.map(\.status) == [.inProgress] && attempts[0].attempt.ordinal == 1)
        #expect(try await memory.count("SELECT count(*) FROM memory_task_occurrences") == 1)
        await memory.store.close()
    }

    @Test("a revision moves the task forward against the one read; a stale one, a foreign producer and a closed task are refused")
    func revisions() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let second = try TaskRevision(
            taskID: "task-1",
            revision: 2,
            recordedAtMS: TaskFixtures.t0 + 10,
            change: .revised,
            reason: "the person asked for PNG",
            content: try TaskFixtures.content("Export as PNG")
        )
        #expect(try await memory.tasks.revise(second, expecting: 1, by: TaskFixtures.producer) == .committed)
        #expect(try await memory.tasks.revise(second, expecting: 1, by: TaskFixtures.producer) == .alreadyApplied,
                "the same revision offered again is a retry")
        let concurrent = try TaskRevision(
            taskID: "task-1",
            revision: 2,
            recordedAtMS: TaskFixtures.t0 + 11,
            change: .revised,
            content: try TaskFixtures.content("Export as GIF")
        )
        await #expect(throws: TaskContextError.staleRevision(taskID: "task-1", expected: 1, current: 2)) {
            _ = try await memory.tasks.revise(concurrent, expecting: 1, by: TaskFixtures.producer)
        }
        let third = try TaskRevision(
            taskID: "task-1",
            revision: 3,
            recordedAtMS: TaskFixtures.t0 + 12,
            change: .revised,
            content: try TaskFixtures.content("Export as TIFF")
        )
        await #expect(throws: TaskContextError.foreignTask(taskID: "task-1")) {
            _ = try await memory.tasks.revise(third, expecting: 2, by: TaskFixtures.other)
        }
        await #expect(throws: TaskContextError.staleRevision(taskID: "task-1", expected: Int.max, current: 2),
                      "a revision read no integer can follow is stale, never a trap") {
            _ = try await memory.tasks.revise(third, expecting: Int.max, by: TaskFixtures.producer)
        }
        await #expect(throws: TaskContextError.foreignTask(taskID: "task-1")) {
            _ = try await memory.tasks.task("task-1", for: TaskFixtures.other)
        }
        await #expect(throws: TaskContextError.unknownTask(taskID: "nothing")) {
            _ = try await memory.tasks.revise(
                try TaskRevision(
                    taskID: "nothing",
                    revision: 2,
                    recordedAtMS: TaskFixtures.t0,
                    change: .revised,
                    content: try TaskFixtures.content()
                ),
                expecting: 1,
                by: TaskFixtures.producer
            )
        }
        let attempt = try #require(try await memory.tasks.attempts(of: "task-1", for: TaskFixtures.producer).first)
        _ = try await memory.tasks.checkpoint(
            try TaskCheckpointDraft(kind: .end, declared: .completed),
            attempt: attempt.attempt.attemptID,
            at: TaskFixtures.t0 + 20,
            by: TaskFixtures.producer
        )
        await #expect(throws: TaskContextError.closed(taskID: "task-1", status: .completed)) {
            _ = try await memory.tasks.revise(third, expecting: 2, by: TaskFixtures.producer)
        }
        await memory.store.close()
    }

    @Test("a checkpoint offered twice is one checkpoint; an end closes the attempt and the task; nothing follows an end")
    func checkpointsAndEnd() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let output = try TaskFixtures.value("output_file", "foto_web.jpg")
        let draft  = try TaskCheckpointDraft(kind: .checkpoint, note: "rotated", outputs: [output])
        let first  = try await memory.tasks.checkpoint(
            draft,
            attempt: "attempt-1",
            at: TaskFixtures.t0 + 5,
            by: TaskFixtures.producer
        )
        let again  = try await memory.tasks.checkpoint(
            draft,
            attempt: "attempt-1",
            at: TaskFixtures.t0 + 6,
            by: TaskFixtures.producer
        )
        #expect(first.receipt == .committed && again.receipt == .alreadyApplied && again.checkpoint.sequence == 1)
        let end = try TaskCheckpointDraft(kind: .end, declared: .failed, note: "the portal refused the file")
        let ended = try await memory.tasks.checkpoint(
            end,
            attempt: "attempt-1",
            at: TaskFixtures.t0 + 9,
            by: TaskFixtures.producer
        )
        #expect(ended.checkpoint.sequence == 2 && ended.receipt == .committed)
        #expect(try await memory.tasks.checkpoint(
            end,
            attempt: "attempt-1",
            at: TaskFixtures.t0 + 10,
            by: TaskFixtures.producer
        ).receipt == .alreadyApplied, "a retried end is the end already stored")
        let task = try #require(try await memory.tasks.task("task-1", for: TaskFixtures.producer))
        #expect(task.status == .failed && task.closedAtMS == TaskFixtures.t0 + 9)
        #expect(try await memory.tasks.attempts(of: "task-1", for: TaskFixtures.producer).map(\.status) == [.failed])
        await #expect(throws: TaskContextError.closed(taskID: "task-1", status: .failed)) {
            _ = try await memory.tasks.checkpoint(
                try TaskCheckpointDraft(kind: .checkpoint, note: "later"),
                attempt: "attempt-1",
                at: TaskFixtures.t0 + 11,
                by: TaskFixtures.producer
            )
        }
        let stored = try await memory.tasks.checkpoints(of: "attempt-1", for: TaskFixtures.producer)
        #expect(stored.map(\.kind) == [.checkpoint, .end] && stored[0].outputs.first?.isExactly(output) == true)
        await memory.store.close()
    }

    @Test("a resumption opens a linked attempt from the current revision and marks the running one interrupted; nothing is replayed")
    func resumption() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let next = try TaskAttempt(
            attemptID: "attempt-2",
            taskID: "task-1",
            ordinal: 2,
            resumes: "attempt-1",
            producer: TaskFixtures.producer,
            openedAtMS: TaskFixtures.t0 + 100,
            openedAtRevision: 1
        )
        #expect(try await memory.tasks.resume(next) == .committed)
        #expect(try await memory.tasks.resume(next) == .alreadyApplied)
        let attempts = try await memory.tasks.attempts(of: "task-1", for: TaskFixtures.producer)
        #expect(attempts.map(\.status) == [.interrupted, .inProgress])
        #expect(attempts[0].endedAtMS == TaskFixtures.t0 + 100 && attempts[1].attempt.resumes == "attempt-1")
        let skipping = try TaskAttempt(
            attemptID: "attempt-3",
            taskID: "task-1",
            ordinal: 3,
            resumes: "attempt-1",
            producer: TaskFixtures.producer,
            openedAtMS: TaskFixtures.t0 + 200,
            openedAtRevision: 1
        )
        await #expect(throws: TaskContextError.unknownAttempt(attemptID: "attempt-1"),
                      "only the last attempt is resumed") {
            _ = try await memory.tasks.resume(skipping)
        }
        await memory.store.close()
    }

    @Test("a secret input keeps its name, role and source and never its text; the contract refuses a secret with its text")
    func secretInput() async throws {
        #expect(throws: TaskContextError.invalid(.secretKept(name: "password"))) {
            _ = try TaskValue(
                name: "password",
                kind: .text,
                content: .text("hunter2"),
                sensitivity: .secret,
                source: .request
            )
        }
        let memory = try await TaskFixtures.open()
        let secret = try TaskValue(
            name: "password",
            role: "account password",
            kind: .text,
            content: .withheld,
            sensitivity: .secret,
            source: .message,
            sourceRef: "message-1"
        )
        let task = try TaskRecord(
            taskID: "task-s",
            producer: TaskFixtures.producer,
            traceID: nil,
            openedAtMS: TaskFixtures.t0,
            status: .open,
            closedAtMS: nil,
            currentRevision: 1
        )
        let revision = try TaskRevision(taskID: "task-s", revision: 1, recordedAtMS: TaskFixtures.t0, change: .opened,
                                        content: try TaskFixtures.content(inputs: [secret]))
        let attempt = try TaskAttempt(
            attemptID: "attempt-s",
            taskID: "task-s",
            ordinal: 1,
            resumes: nil,
            producer: TaskFixtures.producer,
            openedAtMS: TaskFixtures.t0,
            openedAtRevision: 1
        )
        _ = try await memory.tasks.open(task, revision: revision, attempt: attempt)
        let read = try #require(try await memory.tasks.revision(1, of: "task-s", for: TaskFixtures.producer))
        #expect(read.content.inputs.first?.content == .withheld && read.content.inputs.first?.sensitivity == .secret)
        #expect(try await memory.count("""
            SELECT count(*) FROM memory_task_values WHERE text_value IS NOT NULL AND sensitivity = 'secret'
            """) == 0)
        await memory.store.close()
    }

    @Test("the schema refuses what the contract refuses, even written by hand: a revision out of order, a second end, a reopened task")
    func schemaGuards() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        #expect(await refusal(of: """
            INSERT INTO memory_task_revisions (task_id, revision, recorded_at_ms, change_kind, goal)
            VALUES ('task-1', 3, 0, 'revised', 'g')
            """, in: memory.store) != nil)
        _ = try await memory.tasks.checkpoint(
            try TaskCheckpointDraft(kind: .end, declared: .completed),
            attempt: "attempt-1",
            at: TaskFixtures.t0 + 1,
            by: TaskFixtures.producer
        )
        #expect(await refusal(of: """
            INSERT INTO memory_task_checkpoints (task_occurrence_id, sequence, checkpoint_kind, task_id, revision,
                                                 recorded_at_ms, declared_status)
            VALUES ('attempt-1', 2, 'end', 'task-1', 1, 0, 'failed')
            """, in: memory.store) != nil)
        #expect(await refusal(of: """
            UPDATE memory_tasks SET status = 'open', closed_at_ms = NULL WHERE task_id = 'task-1'
            """, in: memory.store) != nil)
        #expect(await refusal(of: """
            UPDATE memory_task_revisions SET goal = 'other' WHERE task_id = 'task-1'
            """, in: memory.store) != nil)
        await memory.store.close()
    }
}

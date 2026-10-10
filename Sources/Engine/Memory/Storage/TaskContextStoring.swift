//
//  TaskContextStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

/// StoredTaskAttempt is an attempt read back with where its episode stands: running while
/// `in_progress`, then completed, failed, cancelled (abandoned) or interrupted (a resumption replaced
/// it). An attempt left `in_progress` by a process that ended stays so: incomplete, never completed.
public struct StoredTaskAttempt: Sendable {
    public let attempt: TaskAttempt
    public let status: TaskStatus
    public let endedAtMS: Int64?

    public init(attempt: TaskAttempt, status: TaskStatus, endedAtMS: Int64?) {
        self.attempt   = attempt
        self.status    = status
        self.endedAtMS = endedAtMS
    }
}

/// TaskContextStoring keeps the tasks agents communicate: their revisions, their attempts as episodes
/// of the memory, the checkpoints and ends they declare with their outputs. It stores what the agent
/// states and checks only references, ownership, revisions and order; it infers no goal, no label
/// and no success. Every write is one transaction and answers after its commit. A task belongs to the
/// producer that opened it: every operation names the producer and another one is refused.
public protocol TaskContextStoring: Sendable {

    /// Opens a task: its record, its first revision and its first attempt, in progress.
    func open(_ task: TaskRecord, revision: TaskRevision, attempt: TaskAttempt) async throws -> MemoryReceipt

    /// Adds a revision after the one the caller read (`expecting`): another current revision is
    /// `staleRevision`, a closed task `closed`. The same revision offered again is `alreadyApplied`.
    func revise(
        _ revision       : TaskRevision,
        expecting current: Int,
        by producer      : TaskProducer
    ) async throws -> MemoryReceipt

    /// Records a checkpoint, or the end that closes the attempt and the task with the declared status,
    /// at the task's current revision. A draft that declares the same as the attempt's last checkpoint
    /// answers that one with `alreadyApplied`: a retried call adds nothing.
    func checkpoint(
        _ draft      : TaskCheckpointDraft,
        attempt      : String,
        at recordedAtMS: Int64,
        by producer  : TaskProducer
    ) async throws -> (receipt: MemoryReceipt, checkpoint: TaskCheckpoint)

    /// Opens a new attempt of an open task, which resumes the last one: a running last attempt is
    /// marked interrupted at the new one's opening instant, in the same transaction.
    func resume(_ attempt: TaskAttempt) async throws -> MemoryReceipt

    /// The task, nil when none is stored under the id; `foreignTask` when it belongs to another producer.
    func task(_ taskID: String, for producer: TaskProducer) async throws -> TaskRecord?

    /// One revision of a task of the producer.
    func revision(_ revision: Int, of taskID: String, for producer: TaskProducer) async throws -> TaskRevision?

    /// The task's attempts by ordinal.
    func attempts(of taskID: String, for producer: TaskProducer) async throws -> [StoredTaskAttempt]

    /// An attempt's checkpoints and end by sequence.
    func checkpoints(of attemptID: String, for producer: TaskProducer) async throws -> [TaskCheckpoint]

    /// The calls attributed to an attempt, by the order they were attributed in.
    func calls(of attemptID: String, for producer: TaskProducer) async throws -> [String]
}

/// OperationFactStoring writes the essential facts of the operations, each group in one transaction
/// answered after its commit: a call confirmed before its effect (`open`), its samples, and its end
/// with its effect and verifications (`conclude`). Its writes are idempotent by identity: the same
/// facts offered again are `alreadyApplied`, another content under the same identity is a typed
/// conflict that writes nothing, so a producer retries a write with the same values and never
/// with a new gesture.
public protocol OperationFactStoring: Sendable {

    /// The call planned and started, its task attribution (an episode membership and the revision)
    /// and its withheld values, in one transaction.
    func open(_ opening: OperationOpening) async throws -> MemoryReceipt

    /// The batch started with its steps planned, attributed as a container of the attempt.
    func open(batch opening: BatchOpening) async throws -> MemoryReceipt

    /// A planned step of a batch started, attributed to the attempt as an operation.
    func start(step eventID: String, atMS: Int64, attribution: TaskCallAttribution?) async throws -> MemoryReceipt

    /// Samples of calls and the gaps withheld values left in them, all or none.
    func record(samples: [CaptureSample], redactions: [ValueRedaction]) async throws -> MemoryReceipt

    /// The call's end: its samples, terminal state and result, effect, verifications, withheld values
    /// and withdrawals, all or none.
    func conclude(_ conclusion: OperationConclusion) async throws -> MemoryReceipt

    func effect(of callEventID: String) async throws -> OperationEffect?

    func verifications(of callEventID: String) async throws -> [OperationVerification]

    func redactions(of eventID: String) async throws -> [ValueRedaction]

    /// The parts of the call's end the archive refused and the call was concluded without: a call with
    /// any is incomplete evidence.
    func recordingGaps(of callEventID: String) async throws -> [OperationRecordingGap]

    func attribution(of callEventID: String) async throws -> TaskCallAttribution?
}

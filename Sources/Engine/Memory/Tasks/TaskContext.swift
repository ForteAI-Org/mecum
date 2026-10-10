//
//  TaskContext.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation

/// TaskContextContract is the versioned contract of the task an agent communicates to Engine: what it
/// is for, what it starts from and what it produced, apart from the operations that serve it. A task
/// call is not a UI step: it records no gesture and is never an operation of a procedure.
public enum TaskContextContract {
    public static let version = 1

    /// The longest text the contract keeps in one field, in UTF-8 bytes. A goal or a value beyond it
    /// is refused, never cut: a cut text would be a value nobody gave.
    public static let maximumTextBytes = 4096

    /// The most constraints, inputs, outputs or message references one revision or checkpoint keeps.
    public static let maximumItems = 64

    /// The number after `number`, a revision's or an attempt's: past the largest integer there is
    /// none, and the value is refused as out of range instead of wrapping or stopping the process.
    public static func successor(of number: Int, field: String) throws -> Int {
        let (next, overflow) = number.addingReportingOverflow(1)
        guard !overflow else { throw TaskContextError.invalid(.outOfRange(field: field)) }
        return next
    }
}

/// TaskValueKind is the base type of a task's value: text, a number, a yes or no, a file or folder by
/// path or reference, a reference to another fact, or a value the task needs and does not have yet.
public enum TaskValueKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case text, number, boolean, file, folder, reference, missing
}

/// TaskValueSource is where a value comes from: the current request, an earlier message of the
/// conversation, an observation of the screen, an earlier task's output, a derivation from values
/// already identified, or a source the agent cannot name.
public enum TaskValueSource: String, Sendable, Equatable, Hashable, CaseIterable {
    case request
    case message
    case observation
    case previousOutput = "previous_output"
    case derived
    case unknown
}

/// TaskValueSensitivity says how a value may be kept. `ordinary` values, private as they may be, are
/// kept locally where the task needs them; a `secret` (a password, a token, a code) is never kept:
/// its name, role and source are, and its content is withheld.
public enum TaskValueSensitivity: String, Sendable, Equatable, Hashable, CaseIterable {
    case ordinary, secret
}

/// TaskValue is one named value of a task: an input it starts from or an output it produced. The
/// name is the agent's, the role its free description; neither comes from a closed vocabulary.
public struct TaskValue: Sendable, Equatable {

    /// Content is what the contract keeps of the value: its text, its absence (a value the task
    /// still needs), or nothing because it is withheld (a secret, or a text a privacy rule removed).
    public enum Content: Sendable, Equatable {
        case text(String)
        case missing
        case withheld
    }

    public let name: String
    public let role: String?
    public let kind: TaskValueKind
    public let content: Content
    public let sensitivity: TaskValueSensitivity
    public let source: TaskValueSource
    /// What the source names: a message id, an earlier task's `task-id/output-name`, a sample key.
    public let sourceRef: String?
    /// The version of that source when it has one: an earlier task's revision or attempt.
    public let sourceVersion: String?

    public init(
        name         : String,
        role         : String? = nil,
        kind         : TaskValueKind,
        content      : Content,
        sensitivity  : TaskValueSensitivity = .ordinary,
        source       : TaskValueSource,
        sourceRef    : String? = nil,
        sourceVersion: String? = nil
    ) throws {
        func refuse(_ invalidity: TaskContextError.Invalidity) -> TaskContextError { .invalid(invalidity) }
        guard !name.isEmpty else { throw refuse(.emptyText(field: "name")) }
        try TaskContextText.check(name, field: "name")
        if let role { try TaskContextText.check(role, field: "role") }
        if let sourceRef { try TaskContextText.check(sourceRef, field: "source_ref") }
        if let sourceVersion { try TaskContextText.check(sourceVersion, field: "source_version") }
        switch (kind, content) {
            case (.missing, .missing): break
            case (.missing, _), (_, .missing): throw refuse(.missingMismatch(name: name))
            case (_, .text(let text)): try TaskContextText.check(text, field: "value")
            case (_, .withheld): break
        }
        if sensitivity == .secret, case .text = content { throw refuse(.secretKept(name: name)) }
        if source == .previousOutput, sourceRef == nil { throw refuse(.previousOutputWithoutReference(name: name)) }
        self.name          = name
        self.role          = role
        self.kind          = kind
        self.content       = content
        self.sensitivity   = sensitivity
        self.source        = source
        self.sourceRef     = sourceRef
        self.sourceVersion = sourceVersion
    }

    /// Whether the other value states exactly the same facts, texts byte for byte.
    public func isExactly(_ other: TaskValue) -> Bool {
        name.utf8.elementsEqual(other.name.utf8) && TaskContextText.same(role, other.role) && kind == other.kind
            && sameContent(other.content) && sensitivity == other.sensitivity && source == other.source
            && TaskContextText.same(sourceRef, other.sourceRef)
            && TaskContextText.same(sourceVersion, other.sourceVersion)
    }

    private func sameContent(_ other: Content) -> Bool {
        switch (content, other) {
            case (.text(let a), .text(let b)): a.utf8.elementsEqual(b.utf8)
            case (.missing, .missing), (.withheld, .withheld): true
            default: false
        }
    }
}

/// TaskRevisionContent is what one revision of a task states: the goal as the agent resolved it from
/// the conversation, the result asked for, the constraints, the inputs and the messages it came from
/// when the frontend knows them. Never the whole conversation.
public struct TaskRevisionContent: Sendable {

    public let goal: String
    public let requestedResult: String?
    public let constraints: [String]
    public let inputs: [TaskValue]
    public let messageRefs: [String]

    public init(
        goal           : String,
        requestedResult: String? = nil,
        constraints    : [String] = [],
        inputs         : [TaskValue] = [],
        messageRefs    : [String] = []
    ) throws {
        func refuse(_ invalidity: TaskContextError.Invalidity) -> TaskContextError { .invalid(invalidity) }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw refuse(.emptyText(field: "goal"))
        }
        try TaskContextText.check(goal, field: "goal")
        if let requestedResult { try TaskContextText.check(requestedResult, field: "result") }
        for (field, count) in [("constraints", constraints.count), ("inputs", inputs.count),
                               ("message_refs", messageRefs.count)]
        where count > TaskContextContract.maximumItems {
            throw refuse(.tooMany(field: field))
        }
        for constraint in constraints {
            guard !constraint.isEmpty else { throw refuse(.emptyText(field: "constraint")) }
            try TaskContextText.check(constraint, field: "constraint")
        }
        try TaskContextText.unique(inputs.map(\.name), field: "inputs")
        for reference in messageRefs {
            guard !reference.isEmpty else { throw refuse(.emptyText(field: "message_ref")) }
            try TaskContextText.check(reference, field: "message_ref")
        }
        try TaskContextText.unique(messageRefs, field: "message_refs")
        self.goal            = goal
        self.requestedResult = requestedResult
        self.constraints     = constraints
        self.inputs          = inputs
        self.messageRefs     = messageRefs
    }

    public func isExactly(_ other: TaskRevisionContent) -> Bool {
        goal.utf8.elementsEqual(other.goal.utf8) && TaskContextText.same(requestedResult, other.requestedResult)
            && constraints.count == other.constraints.count
            && zip(constraints, other.constraints).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
            && inputs.count == other.inputs.count && zip(inputs, other.inputs).allSatisfy { $0.isExactly($1) }
            && messageRefs.count == other.messageRefs.count
            && zip(messageRefs, other.messageRefs).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

/// TaskProducer is who communicates a task: the memory's source and the stream that tells two
/// producers of one source apart. A task belongs to its producer: another one may not revise,
/// checkpoint, close or resume it, and reads nothing of it through the task contract.
public struct TaskProducer: Sendable, Equatable, Hashable {

    public let source: MemoryEventSource
    public let streamID: String

    public init(source: MemoryEventSource, streamID: String) throws {
        guard !streamID.isEmpty else { throw TaskContextError.invalid(.emptyText(field: "stream")) }
        self.source   = source
        self.streamID = streamID
    }

    public func isExactly(_ other: TaskProducer) -> Bool {
        source == other.source && streamID.utf8.elementsEqual(other.streamID.utf8)
    }
}

/// DeclaredTaskStatus is where the agent says a task stands: open while it works, then closed as
/// completed, failed or abandoned. It is the agent's declaration, distinct from any verification and
/// from what a test controls independently.
public enum DeclaredTaskStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case open, completed, failed, abandoned

    public var isClosed: Bool { self != .open }
}

/// TaskRecord is a task as stored: its id, contract version, producer, the trace it was opened in
/// when the frontend has one, its opening instant, its declared status and close, and its current
/// revision.
public struct TaskRecord: Sendable {

    public let taskID: String
    public let contractVersion: Int
    public let producer: TaskProducer
    public let traceID: String?
    public let openedAtMS: Int64
    public let status: DeclaredTaskStatus
    public let closedAtMS: Int64?
    public let currentRevision: Int

    public init(taskID: String, contractVersion: Int = TaskContextContract.version, producer: TaskProducer,
                traceID: String?, openedAtMS: Int64, status: DeclaredTaskStatus, closedAtMS: Int64?,
                currentRevision: Int) throws {
        func refuse(_ invalidity: TaskContextError.Invalidity) -> TaskContextError { .invalid(invalidity) }
        guard !taskID.isEmpty else { throw refuse(.emptyText(field: "task")) }
        guard contractVersion > 0 else { throw refuse(.outOfRange(field: "contract_version")) }
        guard currentRevision >= 1 else { throw refuse(.outOfRange(field: "revision")) }
        for instant in [openedAtMS, closedAtMS].compactMap({ $0 }) where !BrainClock.range.contains(instant) {
            throw refuse(.outOfRange(field: "ms"))
        }
        guard status.isClosed == (closedAtMS != nil) else { throw refuse(.closeMismatch) }
        if let closedAtMS, closedAtMS < openedAtMS { throw refuse(.outOfOrder(field: "closed_at_ms")) }
        self.taskID          = taskID
        self.contractVersion = contractVersion
        self.producer        = producer
        self.traceID         = traceID
        self.openedAtMS      = openedAtMS
        self.status          = status
        self.closedAtMS      = closedAtMS
        self.currentRevision = currentRevision
    }
}

/// TaskRevision is one revision of a task as stored: the number, the instant, why it was made, and
/// what it states. Revisions are never changed: a correction is a new revision.
public struct TaskRevision: Sendable {

    /// Change is why a revision exists: the task was opened, or the agent revised it because the
    /// request or its understanding of it changed.
    public enum Change: String, Sendable, Equatable, Hashable, CaseIterable {
        case opened, revised
    }

    public let taskID: String
    public let revision: Int
    public let recordedAtMS: Int64
    public let change: Change
    public let reason: String?
    public let content: TaskRevisionContent

    public init(taskID: String, revision: Int, recordedAtMS: Int64, change: Change, reason: String? = nil,
                content: TaskRevisionContent) throws {
        func refuse(_ invalidity: TaskContextError.Invalidity) -> TaskContextError { .invalid(invalidity) }
        guard !taskID.isEmpty else { throw refuse(.emptyText(field: "task")) }
        guard revision >= 1 else { throw refuse(.outOfRange(field: "revision")) }
        guard (revision == 1) == (change == .opened) else { throw refuse(.revisionChangeMismatch) }
        guard BrainClock.range.contains(recordedAtMS) else { throw refuse(.outOfRange(field: "ms")) }
        if let reason { try TaskContextText.check(reason, field: "reason") }
        self.taskID       = taskID
        self.revision     = revision
        self.recordedAtMS = recordedAtMS
        self.change       = change
        self.reason       = reason
        self.content      = content
    }

    public func isExactly(_ other: TaskRevision) -> Bool {
        taskID.utf8.elementsEqual(other.taskID.utf8) && revision == other.revision && recordedAtMS == other.recordedAtMS
            && change == other.change && TaskContextText.same(reason, other.reason) && content.isExactly(other.content)
    }
}

/// TaskAttempt is one concrete execution of a task: an episode of the memory (its id is the episode's
/// `task_occurrence_id`), its ordinal within the task, the attempt it resumes when it is a resumption,
/// the producer that runs it and the revision it opened at. A resumption starts from the present as
/// observed; it never replays the attempt it follows.
public struct TaskAttempt: Sendable {

    public let attemptID: String
    public let taskID: String
    public let ordinal: Int
    public let resumes: String?
    public let producer: TaskProducer
    public let openedAtMS: Int64
    public let openedAtRevision: Int

    public init(attemptID: String, taskID: String, ordinal: Int, resumes: String?, producer: TaskProducer,
                openedAtMS: Int64, openedAtRevision: Int) throws {
        func refuse(_ invalidity: TaskContextError.Invalidity) -> TaskContextError { .invalid(invalidity) }
        guard !attemptID.isEmpty, !taskID.isEmpty else { throw refuse(.emptyText(field: "attempt")) }
        guard ordinal >= 1, openedAtRevision >= 1 else { throw refuse(.outOfRange(field: "ordinal")) }
        guard (ordinal == 1) == (resumes == nil) else { throw refuse(.resumptionMismatch) }
        guard BrainClock.range.contains(openedAtMS) else { throw refuse(.outOfRange(field: "ms")) }
        self.attemptID        = attemptID
        self.taskID           = taskID
        self.ordinal          = ordinal
        self.resumes          = resumes
        self.producer         = producer
        self.openedAtMS       = openedAtMS
        self.openedAtRevision = openedAtRevision
    }
}

/// TaskCheckpointDraft is a checkpoint or an end as the agent offers it, before the store gives it
/// its sequence and instant: the kind, the status an end declares, a note and the outputs.
public struct TaskCheckpointDraft: Sendable {

    public let kind: TaskCheckpoint.Kind
    public let declared: DeclaredTaskStatus?
    public let note: String?
    public let outputs: [TaskValue]

    public init(kind: TaskCheckpoint.Kind, declared: DeclaredTaskStatus? = nil, note: String? = nil,
                outputs: [TaskValue] = []) throws {
        func refuse(_ invalidity: TaskContextError.Invalidity) -> TaskContextError { .invalid(invalidity) }
        switch (kind, declared) {
            case (.checkpoint, nil): break
            case (.end, let status?) where status.isClosed: break
            default: throw refuse(.declarationMismatch)
        }
        if let note { try TaskContextText.check(note, field: "note") }
        guard outputs.count <= TaskContextContract.maximumItems else { throw refuse(.tooMany(field: "outputs")) }
        try TaskContextText.unique(outputs.map(\.name), field: "outputs")
        if outputs.contains(where: { $0.kind == .missing }) { throw refuse(.missingOutput) }
        self.kind     = kind
        self.declared = declared
        self.note     = note
        self.outputs  = outputs
    }
}

/// TaskCheckpoint is what the agent declares at a point of an attempt: a checkpoint along the way or
/// the attempt's end, at the revision then current, with a note and the outputs produced so far. The
/// facts of the operations never depend on it: a task interrupted before any checkpoint keeps them.
public struct TaskCheckpoint: Sendable {

    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        case checkpoint, end
    }

    public let attemptID: String
    public let sequence: Int
    public let kind: Kind
    public let revision: Int
    public let recordedAtMS: Int64
    /// The status the end declares; nil on a checkpoint along the way.
    public let declared: DeclaredTaskStatus?
    public let note: String?
    public let outputs: [TaskValue]

    public init(attemptID: String, sequence: Int, kind: Kind, revision: Int, recordedAtMS: Int64,
                declared: DeclaredTaskStatus?, note: String?, outputs: [TaskValue]) throws {
        func refuse(_ invalidity: TaskContextError.Invalidity) -> TaskContextError { .invalid(invalidity) }
        guard !attemptID.isEmpty else { throw refuse(.emptyText(field: "attempt")) }
        guard sequence >= 1, revision >= 1 else { throw refuse(.outOfRange(field: "sequence")) }
        guard BrainClock.range.contains(recordedAtMS) else { throw refuse(.outOfRange(field: "ms")) }
        switch (kind, declared) {
            case (.checkpoint, nil): break
            case (.end, let status?) where status.isClosed: break
            default: throw refuse(.declarationMismatch)
        }
        if let note { try TaskContextText.check(note, field: "note") }
        guard outputs.count <= TaskContextContract.maximumItems else { throw refuse(.tooMany(field: "outputs")) }
        try TaskContextText.unique(outputs.map(\.name), field: "outputs")
        if outputs.contains(where: { $0.kind == .missing }) { throw refuse(.missingOutput) }
        self.attemptID    = attemptID
        self.sequence     = sequence
        self.kind         = kind
        self.revision     = revision
        self.recordedAtMS = recordedAtMS
        self.declared     = declared
        self.note         = note
        self.outputs      = outputs
    }

    /// Whether a draft declares the same things as this checkpoint at the same revision, whatever its
    /// instant: a checkpoint offered again (a retried tool call) is recognized by this.
    public func declaresSame(as draft: TaskCheckpointDraft, at revision: Int) -> Bool {
        kind == draft.kind && self.revision == revision && declared == draft.declared
            && TaskContextText.same(note, draft.note) && outputs.count == draft.outputs.count
            && zip(outputs, draft.outputs).allSatisfy { $0.isExactly($1) }
    }

    /// Whether the other checkpoint states exactly the same facts.
    public func isExactly(_ other: TaskCheckpoint) -> Bool {
        attemptID.utf8.elementsEqual(other.attemptID.utf8) && sequence == other.sequence && kind == other.kind
            && revision == other.revision && recordedAtMS == other.recordedAtMS && declared == other.declared
            && TaskContextText.same(note, other.note) && outputs.count == other.outputs.count
            && zip(outputs, other.outputs).allSatisfy { $0.isExactly($1) }
    }
}

/// TaskCallAttribution places one call in a task attempt, at the revision current when the call
/// began: written with the call's start, in the same transaction, never inferred afterwards from
/// the time or the order of events.
public struct TaskCallAttribution: Sendable, Equatable {

    public let taskID: String
    public let attemptID: String
    public let revision: Int

    public init(taskID: String, attemptID: String, revision: Int) throws {
        guard !taskID.isEmpty, !attemptID.isEmpty else { throw TaskContextError.invalid(.emptyText(field: "attempt")) }
        guard revision >= 1 else { throw TaskContextError.invalid(.outOfRange(field: "revision")) }
        self.taskID    = taskID
        self.attemptID = attemptID
        self.revision  = revision
    }
}

/// TaskContextError is a task operation the store or the contract refuses, sorted by what the caller
/// does next. None of them attributes anything: a refused operation leaves the task as it was.
public enum TaskContextError: Error, Sendable, Equatable {

    /// A request the contract cannot keep: an empty goal, a duplicate name, a secret with its text.
    case invalid(Invalidity)

    /// No task with this id is stored.
    case unknownTask(taskID: String)

    /// No attempt with this id is stored, or it belongs to another task.
    case unknownAttempt(attemptID: String)

    /// The task belongs to another producer: it may not be read, revised, checkpointed, closed or
    /// resumed through this one.
    case foreignTask(taskID: String)

    /// The task is closed: a closed task is never revised, checkpointed or resumed. A new request
    /// opens a new task.
    case closed(taskID: String, status: DeclaredTaskStatus)

    /// The revision the caller read is not the current one: another revision was made meanwhile.
    case staleRevision(taskID: String, expected: Int, current: Int)

    /// The attempt is not running: it ended, or a resumption replaced it.
    case attemptNotRunning(attemptID: String)

    public enum Invalidity: Sendable, Equatable {
        case emptyText(field: String)
        case tooLong(field: String)
        case tooMany(field: String)
        case duplicate(field: String)
        case missingMismatch(name: String)
        case secretKept(name: String)
        case previousOutputWithoutReference(name: String)
        case outOfRange(field: String)
        case outOfOrder(field: String)
        case closeMismatch
        case revisionChangeMismatch
        case resumptionMismatch
        case declarationMismatch
        case missingOutput
    }
}

/// TaskContextText holds the contract's rules for texts: bounded, compared byte for byte.
enum TaskContextText {

    static func check(_ text: String, field: String) throws {
        guard text.utf8.count <= TaskContextContract.maximumTextBytes else {
            throw TaskContextError.invalid(.tooLong(field: field))
        }
    }

    static func unique(_ names: [String], field: String) throws {
        var seen: Set<[UInt8]> = []
        for name in names where !seen.insert(Array(name.utf8)).inserted {
            throw TaskContextError.invalid(.duplicate(field: field))
        }
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
            case (nil, nil)       : true
            case (let a?, let b?) : a.utf8.elementsEqual(b.utf8)
            default               : false
        }
    }
}

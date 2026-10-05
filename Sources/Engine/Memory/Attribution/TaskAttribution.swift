//
//  TaskAttribution.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

/// VerificationScope is what a verification is about: one agent call's result, one step, or a
/// whole task. VerificationMethod is how it was judged: text read in a scene, a control's value or
/// state read back, or a person's answer. Both vocabularies are this contract's proposals: no
/// verifier in production writes them yet, and a verification is a fact whoever produced it.
public enum VerificationScope: String, Sendable, Equatable, Hashable, CaseIterable {
    case call, step, task
}

public enum VerificationMethod: String, Sendable, Equatable, Hashable, CaseIterable {
    case sceneText    = "scene_text"
    case controlValue = "control_value"
    case controlState = "control_state"
    case person
}

/// VerificationVerdict is the store's vocabulary: `unknown` stays unknown, whatever else happened.
public enum VerificationVerdict: String, Sendable, Equatable, Hashable, CaseIterable {
    case passed, failed, unknown
}

/// VerificationRecord is one verification as a fact: its `verification` event and what it judged,
/// expected and observed, each a single text. The step occurrence it may later be attributed to is
/// not part of the fact: it is set apart (`VerificationStoring.attribute`), so an attribution never
/// makes the fact's retry fail and never rewrites it. Compared with `isExactly(_:)`.
public struct VerificationRecord: Sendable {

    public let event: MemoryEventRecord
    public let scope: VerificationScope
    public let method: VerificationMethod
    public let verdict: VerificationVerdict
    public let expectedText: String?
    public let observedText: String?

    public init(event: MemoryEventRecord, scope: VerificationScope, method: VerificationMethod, verdict: VerificationVerdict,
                expectedText: String? = nil, observedText: String? = nil) throws {
        try event.validate()
        guard event.kind == .verification else { throw EventFactError.invalidRecord(.notAVerification) }
        self.event        = event
        self.scope        = scope
        self.method       = method
        self.verdict      = verdict
        self.expectedText = expectedText
        self.observedText = observedText
    }

    /// Whether the other verification states the same facts: the event's immutable content and every
    /// field, texts byte for byte, absent apart from empty.
    public func isExactly(_ other: VerificationRecord) -> Bool {
        event.hasSameImmutableContent(as: other.event) && scope == other.scope && method == other.method && verdict == other.verdict
            && EventFactText.same(expectedText, other.expectedText) && EventFactText.same(observedText, other.observedText)
    }
}

/// StoredVerification is a verification read back: the fact and the step occurrence it is
/// attributed to, nil when none is known.
public struct StoredVerification: Sendable {
    public let record: VerificationRecord
    public let stepOccurrenceID: String?

    public init(record: VerificationRecord, stepOccurrenceID: String?) {
        self.record           = record
        self.stepOccurrenceID = stepOccurrenceID
    }
}

/// TaskStatus is the store's vocabulary of an episode's state. No state machine is derived from the
/// tools: the status is what the caller states, `observed` for an episode seen without a known goal.
public enum TaskStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case observed
    case inProgress = "in_progress"
    case completed, failed, cancelled, interrupted, unknown
}

/// TaskOccurrenceRecord is one episode: an id the caller chose, the trace it ran in when known, its
/// start and its end (nil while not known, never filled with a "now"), and its status. Milliseconds
/// within `BrainClock.range`; the end not before the start. An episode may span applications and
/// sessions: none is imposed. Compared with `isExactly(_:)`.
public struct TaskOccurrenceRecord: Sendable {

    public let taskOccurrenceID: String
    public let traceID: String?
    public let startedAtMS: Int64
    public let endedAtMS: Int64?
    public let status: TaskStatus

    public init(taskOccurrenceID: String, traceID: String? = nil, startedAtMS: Int64, endedAtMS: Int64? = nil,
                status: TaskStatus) throws {
        func refuse(_ invalidity: EventFactError.Invalidity) -> EventFactError { .invalidRecord(invalidity) }
        if taskOccurrenceID.isEmpty { throw refuse(.emptyID) }
        for instant in [startedAtMS, endedAtMS].compactMap({ $0 }) where !BrainClock.range.contains(instant) {
            throw refuse(.outOfRange(field: "ms"))
        }
        if let endedAtMS, endedAtMS < startedAtMS { throw refuse(.outOfOrder(field: "ended_at_ms")) }
        self.taskOccurrenceID = taskOccurrenceID
        self.traceID          = traceID
        self.startedAtMS      = startedAtMS
        self.endedAtMS        = endedAtMS
        self.status           = status
    }

    public func isExactly(_ other: TaskOccurrenceRecord) -> Bool {
        sameIdentity(as: other) && endedAtMS == other.endedAtMS && status == other.status
    }

    /// What an update keeps: the id, the trace and the start.
    public func sameIdentity(as other: TaskOccurrenceRecord) -> Bool {
        taskOccurrenceID.utf8.elementsEqual(other.taskOccurrenceID.utf8) && EventFactText.same(traceID, other.traceID)
            && startedAtMS == other.startedAtMS
    }
}

/// TaskEventRole is the role an event plays in an episode, as attributed: it need not be the event's
/// kind. TaskMembership places one stored event in an episode at a position, the order of the
/// attribution, not a causal order. Compared with `isExactly(_:)`.
public enum TaskEventRole: String, Sendable, Equatable, Hashable, CaseIterable {
    case observation, action, verification, context
}

public struct TaskMembership: Sendable {

    public let taskOccurrenceID: String
    public let eventID: String
    public let position: Int64
    public let role: TaskEventRole

    public init(taskOccurrenceID: String, eventID: String, position: Int64, role: TaskEventRole) throws {
        if taskOccurrenceID.isEmpty || eventID.isEmpty { throw EventFactError.invalidRecord(.emptyID) }
        if position < 0 { throw EventFactError.invalidRecord(.outOfRange(field: "position")) }
        self.taskOccurrenceID = taskOccurrenceID
        self.eventID          = eventID
        self.position         = position
        self.role             = role
    }

    public func isExactly(_ other: TaskMembership) -> Bool {
        taskOccurrenceID.utf8.elementsEqual(other.taskOccurrenceID.utf8) && eventID.utf8.elementsEqual(other.eventID.utf8)
            && position == other.position && role == other.role
    }
}

/// TaskLabelStatus is a label's standing; TaskLabelRecord is one label given to an episode: a
/// stable id, the text as given, who assigned it, an optional confidence in [0, 1] (nil is not
/// zero), the status and the instant. A new assessment is a new label with a new id; no label is
/// chosen as the winner here, and a label proves no success. Compared with `isExactly(_:)`.
public enum TaskLabelStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case candidate, confirmed, rejected
}

public struct TaskLabelRecord: Sendable {

    public let labelID: String
    public let taskOccurrenceID: String
    public let label: String
    public let assignedBy: String
    public let confidence: Double?
    public let status: TaskLabelStatus
    public let assignedAtMS: Int64

    public init(labelID: String, taskOccurrenceID: String, label: String, assignedBy: String, confidence: Double? = nil,
                status: TaskLabelStatus, assignedAtMS: Int64) throws {
        func refuse(_ invalidity: EventFactError.Invalidity) -> EventFactError { .invalidRecord(invalidity) }
        if labelID.isEmpty || taskOccurrenceID.isEmpty { throw refuse(.emptyID) }
        if label.isEmpty { throw refuse(.emptyText(field: "label")) }
        if assignedBy.isEmpty { throw refuse(.emptyText(field: "assigned_by")) }
        if let confidence {
            guard confidence.isFinite else { throw refuse(.notFinite) }
            guard (0...1).contains(confidence) else { throw refuse(.outOfRange(field: "confidence")) }
        }
        if !BrainClock.range.contains(assignedAtMS) { throw refuse(.outOfRange(field: "ms")) }
        self.labelID          = labelID
        self.taskOccurrenceID = taskOccurrenceID
        self.label            = label
        self.assignedBy       = assignedBy
        self.confidence       = confidence
        self.status           = status
        self.assignedAtMS     = assignedAtMS
    }

    public func isExactly(_ other: TaskLabelRecord) -> Bool {
        labelID.utf8.elementsEqual(other.labelID.utf8) && taskOccurrenceID.utf8.elementsEqual(other.taskOccurrenceID.utf8)
            && label.utf8.elementsEqual(other.label.utf8) && assignedBy.utf8.elementsEqual(other.assignedBy.utf8)
            && confidence == other.confidence && status == other.status && assignedAtMS == other.assignedAtMS
    }
}

/// TaskAttribution is an episode with its memberships and labels, written together: all of it or
/// nothing. Every membership and label names the episode.
public struct TaskAttribution: Sendable {

    public let occurrence: TaskOccurrenceRecord
    public let memberships: [TaskMembership]
    public let labels: [TaskLabelRecord]

    public init(occurrence: TaskOccurrenceRecord, memberships: [TaskMembership] = [], labels: [TaskLabelRecord] = []) throws {
        let id = occurrence.taskOccurrenceID
        guard memberships.allSatisfy({ $0.taskOccurrenceID.utf8.elementsEqual(id.utf8) }),
              labels.allSatisfy({ $0.taskOccurrenceID.utf8.elementsEqual(id.utf8) }) else {
            throw EventFactError.invalidRecord(.otherOccurrence)
        }
        self.occurrence  = occurrence
        self.memberships = memberships
        self.labels      = labels
    }
}

/// EventFactError is an observed input, a correlation, a verification or an attribution the store
/// refuses to write or to read.
public enum EventFactError: Error, Sendable, Equatable {

    /// A record no store should keep.
    case invalidRecord(Invalidity)

    /// A detail for an event the store does not hold, or one of another source or kind.
    case missingEvent(eventID: String)
    case wrongEvent(eventID: String, expected: String)

    /// A correlation between events of two different known applications.
    case appMismatch(watcherEventID: String, agentEventID: String)

    /// A membership or a label for an episode the store does not hold, an attribution to a step
    /// occurrence it does not hold.
    case missingOccurrence(id: String)

    /// A membership at a position another attribution already holds.
    case positionTaken(taskOccurrenceID: String, position: Int64)

    /// An update whose expected record is not the stored one, or that changes what names the record.
    case staleExpectation(id: String)
    case immutableField(id: String, field: String)

    /// A verification already attributed to another step occurrence.
    case alreadyAttributed(eventID: String)

    /// A step occurrence already assigned to another task or step, or by another author.
    case alreadyAssigned(id: String)

    /// Step evidence for an occurrence not assigned to that step.
    case occurrenceNotOfStep(stepOccurrenceID: String, stepID: String)

    /// A Route, a step or an experience the store does not hold.
    case missingDefinition(id: String)

    /// A stored row whose shape this contract does not admit.
    case malformedRow(table: String, id: String, malformation: Malformation)

    public enum Invalidity: Sendable, Equatable {
        case emptyID
        case emptyText(field: String)
        case sameEvent
        case notAWatcherInput
        case notAVerification
        case shape(field: String)
        case notFinite
        case outOfRange(field: String)
        case outOfOrder(field: String)
        case otherOccurrence
        case appContradiction
    }

    public enum Malformation: Sendable, Equatable {
        case unknownCode(column: String, code: String)
        case invalid(EventFactError.Invalidity)
    }
}

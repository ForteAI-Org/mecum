//
//  StepOccurrence.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

/// StepOccurrenceRecord is one observed occurrence of a step as a fact: an id the caller chose, its
/// start, its end when known and its status, `TaskStatus`'s vocabulary. The task and the step it
/// belongs to are not part of the fact: they are assigned apart, once, so an assignment never makes
/// the fact's retry fail. Nothing infers a goal, a success or an attempt. Compared with `isExactly(_:)`.
public struct StepOccurrenceRecord: Sendable {

    public let stepOccurrenceID: String
    public let startedAtMS: Int64
    public let endedAtMS: Int64?
    public let status: TaskStatus

    public init(stepOccurrenceID: String, startedAtMS: Int64, endedAtMS: Int64? = nil, status: TaskStatus) throws {
        let probe = try TaskOccurrenceRecord(taskOccurrenceID: stepOccurrenceID, startedAtMS: startedAtMS, endedAtMS: endedAtMS, status: status)
        self.stepOccurrenceID = probe.taskOccurrenceID
        self.startedAtMS      = probe.startedAtMS
        self.endedAtMS        = probe.endedAtMS
        self.status           = probe.status
    }

    public func isExactly(_ other: StepOccurrenceRecord) -> Bool {
        stepOccurrenceID.utf8.elementsEqual(other.stepOccurrenceID.utf8) && startedAtMS == other.startedAtMS
            && endedAtMS == other.endedAtMS && status == other.status
    }
}

/// StoredStepOccurrence is an occurrence read back: the fact and its assignment, each part nil
/// while not assigned.
public struct StoredStepOccurrence: Sendable {
    public let record: StepOccurrenceRecord
    public let taskOccurrenceID: String?
    public let stepID: String?
    public let assignedBy: String?

    public init(record: StepOccurrenceRecord, taskOccurrenceID: String?, stepID: String?, assignedBy: String?) {
        self.record           = record
        self.taskOccurrenceID = taskOccurrenceID
        self.stepID           = stepID
        self.assignedBy       = assignedBy
    }
}

/// StepMembership places a stored event in a step occurrence at a position, with its attempt
/// number when known (nil is not zero) and the attributed role. A `verification` membership agrees
/// with the verification's own attribution.
public struct StepMembership: Sendable {
    public let stepOccurrenceID: String
    public let eventID: String
    public let position: Int64
    public let attemptNumber: Int64?
    public let role: TaskEventRole

    public init(stepOccurrenceID: String, eventID: String, position: Int64, attemptNumber: Int64? = nil, role: TaskEventRole) throws {
        if stepOccurrenceID.isEmpty || eventID.isEmpty { throw EventFactError.invalidRecord(.emptyID) }
        if position < 0 { throw EventFactError.invalidRecord(.outOfRange(field: "position")) }
        if let attemptNumber, attemptNumber < 0 { throw EventFactError.invalidRecord(.outOfRange(field: "attempt_number")) }
        self.stepOccurrenceID = stepOccurrenceID
        self.eventID          = eventID
        self.position         = position
        self.attemptNumber    = attemptNumber
        self.role             = role
    }

    public func isExactly(_ other: StepMembership) -> Bool {
        stepOccurrenceID.utf8.elementsEqual(other.stepOccurrenceID.utf8) && eventID.utf8.elementsEqual(other.eventID.utf8)
            && position == other.position && attemptNumber == other.attemptNumber && role == other.role
    }
}

/// EvidenceRelation is how a judgement relates an occurrence to a definition.
public enum EvidenceRelation: String, Sendable, Equatable, Hashable, CaseIterable {
    case supports, contradicts
}

/// DefinitionEvidence is a judgement a caller gives: a task occurrence for a Route, or a step
/// occurrence for the step it is assigned to, with who judged and when. It is an attribution, never
/// a success inferred from a completed call or a label; nothing selects useful attempts.
public struct DefinitionEvidence: Sendable {

    public enum Subject: Sendable {
        case route(routeID: String, taskOccurrenceID: String)
        case step(stepID: String, stepOccurrenceID: String)
    }

    public let subject: Subject
    public let relation: EvidenceRelation
    public let assessedBy: String
    public let assessedAtMS: Int64

    public init(_ subject: Subject, relation: EvidenceRelation, assessedBy: String, assessedAtMS: Int64) throws {
        switch subject {
            case .route(let a, let b), .step(let a, let b): if a.isEmpty || b.isEmpty { throw EventFactError.invalidRecord(.emptyID) }
        }
        if assessedBy.isEmpty { throw EventFactError.invalidRecord(.emptyText(field: "assessed_by")) }
        if !BrainClock.range.contains(assessedAtMS) { throw EventFactError.invalidRecord(.outOfRange(field: "ms")) }
        self.subject      = subject
        self.relation     = relation
        self.assessedBy   = assessedBy
        self.assessedAtMS = assessedAtMS
    }

    public func isExactly(_ other: DefinitionEvidence) -> Bool {
        let subjects: Bool
        switch (subject, other.subject) {
            case (.route(let a, let b), .route(let c, let d)), (.step(let a, let b), .step(let c, let d)):
                subjects = a.utf8.elementsEqual(c.utf8) && b.utf8.elementsEqual(d.utf8)
            default:
                subjects = false
        }
        return subjects && relation == other.relation && assessedBy.utf8.elementsEqual(other.assessedBy.utf8) && assessedAtMS == other.assessedAtMS
    }
}

/// ExperienceBinding is what an experience gives one of its Route's parameters: a typed literal, or
/// the name of a slot a later request (`requestSlot`) or context (`contextSlot`) will fill. A slot
/// name is a name, never a phrase to interpret now.
public struct ExperienceBinding: Sendable {

    public enum Source: Sendable {
        case literal(BrainArgument.Value)
        case requestSlot(String)
        case contextSlot(String)
    }

    public static let contractVersion = 1

    public let parameterID: String
    public let valueType: ParameterValueType
    public let source: Source

    public init(parameterID: String, valueType: ParameterValueType, source: Source) throws {
        func refuse(_ invalidity: EventFactError.Invalidity) -> EventFactError { .invalidRecord(invalidity) }
        if parameterID.isEmpty { throw refuse(.emptyID) }
        switch source {
            case .literal(let value):
                guard ParameterValueType(value.kind) == valueType else { throw refuse(.shape(field: "literal")) }
                if case .real(let real) = value, !real.isFinite { throw refuse(.notFinite) }
            case .requestSlot(let name), .contextSlot(let name):
                guard name.contains(where: { $0 != " " }) else { throw refuse(.emptyText(field: "slot_name")) }
        }
        self.parameterID = parameterID
        self.valueType   = valueType
        self.source      = source
    }
}

/// ExperienceRecord is a phrase a person used, pointing at a Route or at one step of the same
/// Route, with the bindings of the Route's parameters. Nothing ranks, matches or recalls it.
/// Compared with `isExactly(_:)`, bindings by parameter id.
public struct ExperienceRecord: Sendable {

    public let experienceID: String
    public let phrase: String
    public let routeID: String
    public let stepID: String?
    public let createdAtMS: Int64
    public let bindings: [ExperienceBinding]

    public init(experienceID: String, phrase: String, routeID: String, stepID: String? = nil, createdAtMS: Int64,
                bindings: [ExperienceBinding] = []) throws {
        func refuse(_ invalidity: EventFactError.Invalidity) -> EventFactError { .invalidRecord(invalidity) }
        if experienceID.isEmpty || routeID.isEmpty { throw refuse(.emptyID) }
        if let stepID, stepID.isEmpty { throw refuse(.emptyID) }
        if phrase.isEmpty { throw refuse(.emptyText(field: "phrase")) }
        if !BrainClock.range.contains(createdAtMS) { throw refuse(.outOfRange(field: "ms")) }
        guard Set(bindings.map { Array($0.parameterID.utf8) }).count == bindings.count else { throw refuse(.shape(field: "bindings")) }
        self.experienceID = experienceID
        self.phrase       = phrase
        self.routeID      = routeID
        self.stepID       = stepID
        self.createdAtMS  = createdAtMS
        self.bindings     = bindings.sorted { Array($0.parameterID.utf8).lexicographicallyPrecedes(Array($1.parameterID.utf8)) }
    }

    public func isExactly(_ other: ExperienceRecord) -> Bool {
        func same(_ a: ExperienceBinding, _ b: ExperienceBinding) -> Bool {
            guard a.parameterID.utf8.elementsEqual(b.parameterID.utf8), a.valueType == b.valueType else { return false }
            switch (a.source, b.source) {
                case (.literal(let x), .literal(let y)):
                    return BrainArgument.exactlyEqual([BrainArgument(name: "v", position: 0, value: x)], [BrainArgument(name: "v", position: 0, value: y)])
                case (.requestSlot(let x), .requestSlot(let y)), (.contextSlot(let x), .contextSlot(let y)):
                    return x.utf8.elementsEqual(y.utf8)
                default:
                    return false
            }
        }
        return experienceID.utf8.elementsEqual(other.experienceID.utf8) && phrase.utf8.elementsEqual(other.phrase.utf8)
            && routeID.utf8.elementsEqual(other.routeID.utf8) && EventFactText.same(stepID, other.stepID) && createdAtMS == other.createdAtMS
            && bindings.count == other.bindings.count && zip(bindings, other.bindings).allSatisfy(same)
    }
}

/// ExperienceUse is one use of an experience in an event, with the verdict given for it; counts of
/// uses are derived from these rows, never kept apart.
public struct ExperienceUse: Sendable {
    public let experienceID: String
    public let eventID: String
    public let verdict: VerificationVerdict

    public init(experienceID: String, eventID: String, verdict: VerificationVerdict) throws {
        if experienceID.isEmpty || eventID.isEmpty { throw EventFactError.invalidRecord(.emptyID) }
        self.experienceID = experienceID
        self.eventID      = eventID
        self.verdict      = verdict
    }
}

public struct ExperienceUseCounts: Sendable, Equatable {
    public let passed: Int
    public let failed: Int
    public let unknown: Int

    public init(passed: Int, failed: Int, unknown: Int) {
        self.passed  = passed
        self.failed  = failed
        self.unknown = unknown
    }
}

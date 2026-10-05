//
//  RouteStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

/// RouteStoring keeps procedures as definitions: a Route with its parameters, steps, checks,
/// operations, arguments and call bindings, written whole or not at all, and its state, changed
/// deliberately. It runs no Route, resolves no target and certifies nothing: publication is a
/// structural check, not proof that the procedure works.
public protocol RouteStoring: Sendable {

    /// Records a definition with its initial state. The same definition again is `alreadyApplied`
    /// whatever its state became since; another definition under the id is a conflict.
    func record(_ definition: RouteDefinition, state: RouteState) async throws -> MemoryReceipt

    /// Changes a Route's state against the state last read: `staleExpectation` when another writer
    /// moved it first; publication is checked again when it becomes active.
    func update(_ routeID: String, from expected: RouteState, to updated: RouteState) async throws -> MemoryReceipt

    func route(_ routeID: String) async throws -> StoredRoute?
}

/// StepOccurrenceStoring keeps observed step occurrences, their assignment to a task and a step,
/// the events attributed to them and the evidence a caller gives for Routes and steps. It infers
/// nothing and selects no attempt.
public protocol StepOccurrenceStoring: Sendable {

    /// Records an occurrence once by its id.
    func record(_ occurrence: StepOccurrenceRecord) async throws -> MemoryReceipt

    /// Changes an occurrence's end and status against the record last read.
    func update(from expected: StepOccurrenceRecord, to updated: StepOccurrenceRecord) async throws -> MemoryReceipt

    /// Assigns an occurrence to a task and to a step, each once: the same again is `alreadyApplied`,
    /// another task, step or author `alreadyAssigned`.
    func assign(_ stepOccurrenceID: String, toTask taskOccurrenceID: String?, step stepID: String?, by author: String) async throws -> MemoryReceipt

    /// Places a stored event in an occurrence, once by (occurrence, event, role).
    func record(_ membership: StepMembership) async throws -> MemoryReceipt

    /// Attributes a verification to an occurrence and records its `verification` membership, in
    /// one transaction, so the two never disagree in between.
    func attribute(verification eventID: String, to membership: StepMembership) async throws -> MemoryReceipt

    /// Records evidence once by its subject and relation.
    func record(_ evidence: DefinitionEvidence) async throws -> MemoryReceipt

    func occurrence(_ stepOccurrenceID: String) async throws -> StoredStepOccurrence?
    func memberships(of stepOccurrenceID: String) async throws -> [StepMembership]
    func evidence(ofRoute routeID: String) async throws -> [DefinitionEvidence]
    func evidence(ofStep stepID: String) async throws -> [DefinitionEvidence]
}

/// ExperienceStoring keeps experiences with their bindings, and their uses. It ranks, matches and
/// recalls nothing: an experience is found by its id, its Route or its exact phrase.
public protocol ExperienceStoring: Sendable {

    func record(_ experience: ExperienceRecord) async throws -> MemoryReceipt
    func record(_ use: ExperienceUse) async throws -> MemoryReceipt
    func experience(_ experienceID: String) async throws -> ExperienceRecord?
    func experiences(ofRoute routeID: String) async throws -> [ExperienceRecord]

    /// The experiences whose phrase is these bytes exactly; no normalization, no fuzzy match.
    func experiences(phrase: String) async throws -> [ExperienceRecord]

    func uses(of experienceID: String) async throws -> [ExperienceUse]

    /// The counts of an experience's uses by verdict, derived from the uses.
    func useCounts(of experienceID: String) async throws -> ExperienceUseCounts
}

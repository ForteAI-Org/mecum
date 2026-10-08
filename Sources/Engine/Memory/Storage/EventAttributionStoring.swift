//
//  EventAttributionStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

/// ObservedInputStoring keeps the Watcher's inputs and the correlations a caller states between an
/// input and an agent call. It observes nothing and correlates nothing on its own. An input is
/// recorded with its event in one transaction; an event a capture stored first is completed with
/// the detail, never rewritten. The same identity and facts are `alreadyApplied`; other facts under
/// the identity are `MemoryStoreError.identity` with nothing written.
public protocol ObservedInputStoring: Sendable {

    func record(_ input: ObservedInputRecord) async throws -> MemoryReceipt

    func input(_ eventID: String) async throws -> ObservedInputRecord?

    /// Records a correlation, once by its Watcher event: another attribution of that input is a
    /// conflict, never an overwrite. Both events must exist, the first a `watcher` `input`, the
    /// second an `app` or `cli` `action`, and their applications must agree when both are known.
    func record(_ correlation: ActionCorrelation) async throws -> MemoryReceipt

    func correlation(ofWatcherEvent eventID: String) async throws -> ActionCorrelation?

    /// The correlations naming an agent call, in the local order of their Watcher events.
    func correlations(ofAgentEvent eventID: String) async throws -> [ActionCorrelation]
}

/// VerificationStoring keeps verifications as facts and, apart from them, the step occurrence a
/// verification is attributed to. It judges nothing.
public protocol VerificationStoring: Sendable {

    /// Records a verification with its event in one transaction, once by its event.
    func record(_ verification: VerificationRecord) async throws -> MemoryReceipt

    /// Attributes a stored verification to a stored step occurrence, once: the same occurrence again
    /// is `alreadyApplied`, another is `EventFactError.alreadyAttributed`.
    func attribute(verification eventID: String, toStepOccurrence stepOccurrenceID: String) async throws -> MemoryReceipt

    func verification(_ eventID: String) async throws -> StoredVerification?
}

/// TaskAttributionStoring keeps episodes, the events attributed to them and their labels, as the
/// caller states them: it segments nothing, infers no label and chooses none.
public protocol TaskAttributionStoring: Sendable {

    /// Records an episode once by its id.
    func record(_ occurrence: TaskOccurrenceRecord) async throws -> MemoryReceipt

    /// Changes an episode's end and status against the record last read: the stored one must be
    /// `expected` exactly, else `staleExpectation`; the id, the trace and the start stay.
    func update(from expected: TaskOccurrenceRecord, to updated: TaskOccurrenceRecord) async throws -> MemoryReceipt

    /// Places a stored event in a stored episode, once by (episode, event, role); a position
    /// another attribution holds is `positionTaken`.
    func record(_ membership: TaskMembership) async throws -> MemoryReceipt

    /// Records a label once by its id.
    func record(_ label: TaskLabelRecord) async throws -> MemoryReceipt

    /// Records an episode, its memberships and its labels in one transaction: all or nothing.
    func attribute(_ attribution: TaskAttribution) async throws -> MemoryReceipt

    func occurrence(_ taskOccurrenceID: String) async throws -> TaskOccurrenceRecord?

    /// An episode's memberships by position.
    func memberships(of taskOccurrenceID: String) async throws -> [TaskMembership]

    /// An episode's labels by assignment instant, then id.
    func labels(of taskOccurrenceID: String) async throws -> [TaskLabelRecord]
}

//
//  LivingMemoryStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

/// ExperienceRecording is what recording one event did.
public enum ExperienceRecording: Sendable, Equatable {

    /// The event was new and its effect is stored; the experience it belongs to, if any.
    case applied(ExperienceRecord?)

    /// The identical event was already recorded and nothing changed; the experience it belongs to.
    case duplicate(ExperienceRecord?)

    public var experience: ExperienceRecord? {
        switch self {
            case .applied(let record), .duplicate(let record): record
        }
    }
}

/// LivingMemoryStoring keeps the living memory beside the brain: sightings of objects in window
/// contexts, experiences with their proof and history, and the reasons for recall decisions. It is
/// storage only; what is admitted, suggested or trusted is decided in Memory's pure rules.
///
/// The contract every conformer keeps, in memory or on disk:
/// - Each call is one atomic step. A thrown call leaves the store unchanged, and a batch of
///   sightings is applied entirely or not at all.
/// - Concurrent calls serialize: no update is lost, and a read sees every write that returned.
/// - A write returns only once it is as durable as the conformer promises; a persistent conformer
///   has committed it. Nothing is queued to be written later.
/// - An event or decision is applied at most once per id; the identical call again is a no-op
///   and the same id with other content is refused.
/// - Counters change only by `Sighting.merge` and `ExperienceEventRule`, never by a read-modify-write
///   outside the atomic step.
/// - Reads return values sorted deterministically; an unreadable store throws rather than answering
///   empty, so "nothing remembered" always means the store was read.
public protocol LivingMemoryStoring: Sendable {

    /// Creates or merges one sighting per observation, in order, and returns the resulting records.
    func recordSightings(_ observations: [SightingObservation]) async throws -> [Sighting]

    /// The sightings of the given applications, sorted by bundle, window family and identity.
    func sightings(in bundleIDs: Set<String>) async throws -> [Sighting]

    /// Records one experience event under `ExperienceEventRule`.
    func record(_ event: ExperienceEvent) async throws -> ExperienceRecording

    /// The experiences of the given applications, oldest first.
    func experiences(in bundleIDs: Set<String>) async throws -> [ExperienceRecord]

    /// One experience's history, in recording order.
    func history(of experience: ExperienceID) async throws -> [ExperienceHistoryEntry]

    /// The experiences a phrase could be about under `ExperienceRecord.isCandidate`, oldest first,
    /// limited to the given applications when `bundleIDs` is not nil.
    func candidates(for phrase: String, in bundleIDs: Set<String>?) async throws -> [ExperienceRecord]

    /// Records one recall decision, at most once per id.
    func record(_ decision: RecallDecisionRecord) async throws

    /// The decisions about one experience, in recording order.
    func decisions(about experience: ExperienceID) async throws -> [RecallDecisionRecord]
}

//
//  InMemoryLivingMemoryStore.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation

/// InMemoryLivingMemoryStore is `LivingMemoryStoring` over dictionaries: the store for a test or a
/// session that must leave nothing on disk. Actor isolation is the serialization the role asks for,
/// and no method suspends while it changes state, so each call is one atomic step. Nothing is
/// durable: the memory ends with the actor.
public actor InMemoryLivingMemoryStore: LivingMemoryStoring {

    private let makeID: @Sendable () -> ExperienceID
    private var sightingsByKey: [SightingKey: Sighting] = [:]
    private var experiencesByID: [ExperienceID: ExperienceRecord] = [:]
    private var experienceIDsByNaturalKey: [String: ExperienceID] = [:]
    private var entries: [ExperienceHistoryEntry] = []
    private var entryIndexByEventID: [String: Int] = [:]
    private var decisionsInOrder: [RecallDecisionRecord] = []
    private var decisionIndexByID: [String: Int] = [:]

    /// - Parameter makeID: supplies a new experience's persistent id; a random UUID by default.
    public init(makeID: @escaping @Sendable () -> ExperienceID = { ExperienceID(UUID().uuidString) }) {
        self.makeID = makeID
    }

    // MARK: Sightings

    public func recordSightings(_ observations: [SightingObservation]) -> [Sighting] {
        var touched: [SightingKey] = []
        for observation in observations {
            if var sighting = sightingsByKey[observation.key] {
                sighting.merge(observation)
                sightingsByKey[observation.key] = sighting
            } else {
                sightingsByKey[observation.key] = Sighting(first: observation)
            }
            if !touched.contains(observation.key) { touched.append(observation.key) }
        }
        return touched.compactMap { sightingsByKey[$0] }
    }

    public func sightings(in bundleIDs: Set<String>) -> [Sighting] {
        sightingsByKey.values
            .filter { bundleIDs.contains($0.key.context.bundleID) }
            .sorted(by: Sighting.isOrderedBefore)
    }

    // MARK: Experiences

    public func record(_ event: ExperienceEvent) throws -> ExperienceRecording {
        let previous = entryIndexByEventID[event.id].map { entries[$0] }
        let target: ExperienceRecord? = switch event.subject {
            case .step(let draft)   : experienceIDsByNaturalKey[draft.naturalKey].flatMap { experiencesByID[$0] }
            case .experience(let id): experiencesByID[id]
            case .unattributed      : nil
        }
        switch try ExperienceEventRule.resolve(event, previous: previous, target: target, newID: makeID) {
            case .duplicate(let id):
                return .duplicate(id.flatMap { experiencesByID[$0] })
            case .write(let entry, let record):
                if let record {
                    experiencesByID[record.id] = record
                    experienceIDsByNaturalKey[record.draft.naturalKey] = record.id
                }
                entryIndexByEventID[event.id] = entries.count
                entries.append(entry)
                return .applied(record)
        }
    }

    public func experiences(in bundleIDs: Set<String>) -> [ExperienceRecord] {
        experiencesByID.values
            .filter { bundleIDs.contains($0.context.bundleID) }
            .sorted(by: ExperienceRecord.isOrderedBefore)
    }

    public func history(of experience: ExperienceID) -> [ExperienceHistoryEntry] {
        entries.filter { $0.experienceID == experience }
    }

    public func candidates(for phrase: String, in bundleIDs: Set<String>?) -> [ExperienceRecord] {
        let tokens = Set(GoalPhrase.tokens(phrase))
        return experiencesByID.values
            .filter { bundleIDs?.contains($0.context.bundleID) ?? true }
            .filter { $0.isCandidate(forPhraseTokens: tokens) }
            .sorted(by: ExperienceRecord.isOrderedBefore)
    }

    // MARK: Recall decisions

    public func record(_ decision: RecallDecisionRecord) throws {
        if let index = decisionIndexByID[decision.id] {
            guard decisionsInOrder[index] == decision else {
                throw LivingMemoryError.conflictingDecision(id: decision.id)
            }
            return
        }
        decisionIndexByID[decision.id] = decisionsInOrder.count
        decisionsInOrder.append(decision)
    }

    public func decisions(about experience: ExperienceID) -> [RecallDecisionRecord] {
        decisionsInOrder.filter { $0.experienceID == experience }
    }
}

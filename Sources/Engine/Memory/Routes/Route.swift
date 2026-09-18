//
//  Route.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// Route is a named, replayable procedure learned from a successful use. A route is a belief: only a
/// proof may create one, a contradiction demotes it, and demotion never erases. The demoted row keeps
/// its steps and says what contradicted them, which is what makes the next audit possible.
public struct Route: Sendable, Equatable, Codable {

    public var name: String
    public var steps: [RouteStep]
    /// Independent confirmations, one at learning.
    public var evidence: Int
    /// Consecutive replay failures.
    public var failStreak: Int
    public var firstLearned: Date
    public var lastUsed: Date
    /// What verified the goal when the route was written; absent on rows written before proofs.
    public var proof: String?
    /// When a contradiction retracted it. Non-nil means kept, readable, never replayed.
    public var demotedAt: Date?
    /// What contradicted it, verbatim where a person said it.
    public var demotionCause: String?

    public init(
        name         : String,
        steps        : [RouteStep],
        evidence     : Int = 1,
        failStreak   : Int = 0,
        firstLearned : Date,
        lastUsed     : Date,
        proof        : String? = nil,
        demotedAt    : Date? = nil,
        demotionCause: String? = nil
    ) {
        self.name          = name
        self.steps         = steps
        self.evidence      = evidence
        self.failStreak    = failStreak
        self.firstLearned  = firstLearned
        self.lastUsed      = lastUsed
        self.proof         = proof
        self.demotedAt     = demotedAt
        self.demotionCause = demotionCause
    }

    /// Whether this route was ever earned: a proof, or, for a row that predates proofs, enough
    /// independent confirmations to have the substance of one.
    public var isEarned: Bool { proof != nil || evidence >= RoutePolicy.confirmationsInsteadOfProof }

    /// Whether the engine may act on this route. Actionability is what a contradiction removes.
    public var isActionable: Bool {
        demotedAt == nil && failStreak < RoutePolicy.forgetAfterFails && isEarned
    }

    /// Retracts this belief. The first cause is the true one; a later contradiction does not overwrite
    /// the history. Returns false when already demoted.
    mutating func demote(cause: String, now: Date) -> Bool {
        guard demotedAt == nil else { return false }
        demotedAt     = now
        demotionCause = cause
        return true
    }

    /// Scores a query against the route's name on content tokens, falling back to the raw phrases
    /// when filtering empties one side.
    public func matchScore(query: String) -> Double {
        let queryContent = GoalPhrase.content(query), nameContent = GoalPhrase.content(name)
        let filtered = (queryContent.isEmpty || nameContent.isEmpty)
            ? 0
            : LabelText.matchScore(query: queryContent, against: nameContent)
        return max(filtered, LabelText.matchScore(query: query, against: name))
    }

    /// The learned end state: the letters family of the window title after the final step, if recorded.
    public var endTitleFamily: String? {
        steps.last?.afterTitle.flatMap { $0.isEmpty ? nil : $0 }
    }
}

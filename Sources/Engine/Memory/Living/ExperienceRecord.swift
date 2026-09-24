//
//  ExperienceRecord.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation

/// ExperienceRecord is a durable experience: "for this phrase, in this window, this step was
/// performed and this result was verified". It keeps the original phrase, the semantic step, the
/// latest verified proof, and counters that only its events move.
///
/// A record is history, never permission. Whether it may be suggested is recall's decision, and
/// any action it inspires resolves its control again in a fresh scene.
public struct ExperienceRecord: Sendable, Equatable, Codable {

    public let id: ExperienceID
    public let draft: ExperienceDraft
    public let createdAt: Date

    /// Verified successes. A contradiction never lowers it.
    public var successCount: Int

    /// Contradictions: verified failures and corrections. Uncertain attempts are not counted.
    public var failureCount: Int

    /// The proof of the latest verified success.
    public var latestProof: DropdownEvidence?
    public var lastVerifiedAt: Date?
    public var lastContradictedAt: Date?

    public init(
        id                : ExperienceID,
        draft             : ExperienceDraft,
        createdAt         : Date,
        successCount      : Int = 0,
        failureCount      : Int = 0,
        latestProof       : DropdownEvidence? = nil,
        lastVerifiedAt    : Date? = nil,
        lastContradictedAt: Date? = nil
    ) {
        self.id                 = id
        self.draft              = draft
        self.createdAt          = createdAt
        self.successCount       = successCount
        self.failureCount       = failureCount
        self.latestProof        = latestProof
        self.lastVerifiedAt     = lastVerifiedAt
        self.lastContradictedAt = lastContradictedAt
    }

    public var context: WindowContext { draft.context }
    public var phrase: String { draft.phrase }
    public var step: ExperienceStep { draft.step }

    /// Applies one outcome's effect on the counters. Events are applied in recording order; the
    /// latest proof follows the newest verification by date, so a late write never replaces it.
    public mutating func apply(_ outcome: ExperienceEvent.Outcome, at date: Date) {
        switch outcome {
            case .verified(let proof):
                successCount += 1
                if lastVerifiedAt.map({ date >= $0 }) ?? true {
                    lastVerifiedAt = date
                    latestProof    = proof
                }
            case .contradicted:
                failureCount += 1
                lastContradictedAt = max(lastContradictedAt ?? date, date)
            case .noChange, .uncertain:
                break
        }
    }

    /// The record as recall's `Experience`: the original phrase, the step's semantic arguments as
    /// sorted JSON, the counters, and this record's id as the source.
    public var recallExperience: Experience {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // A dictionary of strings always encodes, so the empty object is never used.
        let arguments = (try? encoder.encode(step.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return Experience(phrase: phrase, tool: step.tool.rawValue, argsJSON: arguments,
                          ok: successCount, fail: failureCount, source: id)
    }

    /// The order every store returns experiences in: oldest first, then by id.
    public static func isOrderedBefore(_ lhs: ExperienceRecord, _ rhs: ExperienceRecord) -> Bool {
        (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
    }

    /// Whether a phrase with these goal tokens could be about this experience: it shares a token
    /// with the original phrase or with the step's own terms. A candidate is not a match; recall
    /// decides. The one rule every store applies, so candidate sets agree across adapters.
    public func isCandidate(forPhraseTokens tokens: Set<String>) -> Bool {
        !tokens.isDisjoint(with: draft.phraseTokens) || !tokens.isDisjoint(with: step.terms)
    }
}

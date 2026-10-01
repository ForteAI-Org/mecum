//
//  RecallDecisionRecord.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation

/// RecallDecisionRecord is why recall suggested, refused or abstained for one phrase, kept so an
/// inspector can explain a decision without reconstructing it. Structured text only: the phrase,
/// the context consulted, the experience considered, the verdict and the reason.
///
/// `id` is the recorder's idempotency key, as for an `ExperienceEvent`.
public struct RecallDecisionRecord: Sendable, Equatable, Codable {

    public enum Verdict: String, Sendable, Equatable, Codable {
        case suggested
        case refused
        case abstained
    }

    public let id: String
    public let at: Date
    public let phrase: String

    /// The window context consulted, when one was known at decision time.
    public let context: WindowContext?

    /// The experience considered, when the decision was about one.
    public let experienceID: ExperienceID?
    public let verdict: Verdict
    public let reason: String

    public init(
        id          : String,
        at          : Date,
        phrase      : String,
        context     : WindowContext?,
        experienceID: ExperienceID?,
        verdict     : Verdict,
        reason      : String
    ) {
        self.id           = id
        self.at           = at
        self.phrase       = phrase
        self.context      = context
        self.experienceID = experienceID
        self.verdict      = verdict
        self.reason       = reason
    }
}

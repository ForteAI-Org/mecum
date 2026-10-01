//
//  ExperienceDraft.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation

/// ExperienceDraft is what an experience is about before it has an identity: the original phrase,
/// the verified step, and the window context. Its natural key decides whether a new verification
/// strengthens an existing experience or starts one.
public struct ExperienceDraft: Sendable, Equatable, Codable {

    /// The user's phrase exactly as written.
    public let phrase: String
    public let step: ExperienceStep
    public let context: WindowContext

    /// A draft, or nil when the phrase has no goal content to be recalled by.
    public init?(phrase: String, step: ExperienceStep, context: WindowContext) {
        guard !GoalPhrase.tokens(phrase).isEmpty else { return nil }
        self.phrase  = phrase
        self.step    = step
        self.context = context
    }

    /// The phrase's goal tokens.
    public var phraseTokens: Set<String> { Set(GoalPhrase.tokens(phrase)) }

    /// Context, goal tokens and step: two phrasings with the same goal content and the same step in
    /// the same window are one experience; any difference is another.
    public var naturalKey: String {
        [context.bundleID, context.windowFamily, phraseTokens.sorted().joined(separator: " "), step.key]
            .joined(separator: "\n")
    }
}

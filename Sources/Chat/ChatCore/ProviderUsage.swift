//
//  ProviderUsage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation

/// ProviderUsage is what a provider reported one turn cost, in counts that mean the same for every
/// provider. Fields the provider did not report are nil or empty, never guessed.
///
/// `tokens` is the turn's own usage, except where `isSessionTotal` says the provider counts the whole
/// session so far (Codex): the caller, which knows the session's previous total, takes the difference.
/// `contextTokens` is how much of the model's context the conversation fills after the turn, which is
/// not what the turn used: a turn that reads a cached history of 100k tokens twice uses 200k.
public struct ProviderUsage: Sendable, Equatable {

    /// Token counts. `input` is every token the model read, cached or not; `cacheReads` and
    /// `cacheWrites` are the parts of it read from and written to the prompt cache. `reasoning` is
    /// the part of `output` spent thinking. The app stores this coded form, so a renamed property
    /// is a new payload version there.
    public struct Tokens: Sendable, Hashable, Codable {
        public var input: Int
        public var cacheReads: Int
        public var cacheWrites: Int
        public var output: Int
        public var reasoning: Int

        public init(input: Int = 0, cacheReads: Int = 0, cacheWrites: Int = 0, output: Int = 0, reasoning: Int = 0) {
            self.input = input
            self.cacheReads = cacheReads
            self.cacheWrites = cacheWrites
            self.output = output
            self.reasoning = reasoning
        }
    }

    /// One usage limit of the account, as the provider names its window: `five_hour` and `seven_day`
    /// for Claude, `primary` and `secondary` for Codex. `usedFraction` runs from 0 to 1.
    /// The app stores this coded form too.
    public struct RateLimit: Sendable, Hashable, Codable {
        public var window: String
        public var usedFraction: Double
        public var resetsAt: Date?
        /// The window's length, when the provider states it (Codex).
        public var windowMinutes: Int?

        public init(window: String, usedFraction: Double, resetsAt: Date? = nil, windowMinutes: Int? = nil) {
            self.window = window
            self.usedFraction = usedFraction
            self.resetsAt = resetsAt
            self.windowMinutes = windowMinutes
        }
    }

    public var tokens: Tokens
    public var isSessionTotal: Bool
    /// The model as the provider named it for this turn.
    public var model: String?
    public var contextTokens: Int?
    /// The model's context window in tokens.
    public var contextWindow: Int?
    public var rateLimits: [RateLimit]

    public init(tokens: Tokens, isSessionTotal: Bool = false, model: String? = nil, contextTokens: Int? = nil,
                contextWindow: Int? = nil, rateLimits: [RateLimit] = []) {
        self.tokens = tokens
        self.isSessionTotal = isSessionTotal
        self.model = model
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.rateLimits = rateLimits
    }
}

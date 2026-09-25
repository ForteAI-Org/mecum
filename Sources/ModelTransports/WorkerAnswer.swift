//
//  WorkerAnswer.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// WorkerAnswer is how a worker on a provider answers a message, and the one
/// place that says so (§18.2): the picker, the composer and the turn all ask
/// it, so no second list of providers that answer can drift from this one.
///
/// An agent is an external command line that runs its own loop with Mecum's
/// tools (§7.1). The other providers are models this build has no agent for.
public enum WorkerAnswer: Sendable, Hashable {

    /// The provider's command line answers as an agent.
    case agent

    /// Nothing answers yet, for the reason given.
    case notYet(reason: String)

    public init(provider: ModelProvider) {
        switch provider {
        case .claudeCode, .codex:
            self = .agent
        case .anthropic, .gemini, .ollama:
            self = .notYet(reason: "this provider is not available for workers in this version")
        }
    }

    /// Why nothing answers, or nil when an agent does.
    public var refusal: String? {
        switch self {
        case .agent:                  nil
        case .notYet(let reason):     reason
        }
    }
}

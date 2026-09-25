//
//  WorkerAnswer.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// WorkerAnswer is how a worker on a provider answers a message, and the one
/// place that says so (§18.2): the host and the turn ask it, so no second list
/// of which provider runs which loop can drift from this one.
///
/// An agent is an external command line that runs its own loop with Mecum's
/// tools (§7.1). A model provider has no loop of its own, so Mecum runs one
/// over its transport, with the same tools when the model can call them.
public enum WorkerAnswer: Sendable, Hashable {

    /// The provider's command line answers as an agent.
    case agent

    /// The provider's model answers through Mecum's own loop over its transport.
    case modelLoop

    public init(provider: ModelProvider) {
        switch provider {
        case .claudeCode, .codex:
            self = .agent
        case .anthropic, .gemini, .ollama:
            self = .modelLoop
        }
    }
}

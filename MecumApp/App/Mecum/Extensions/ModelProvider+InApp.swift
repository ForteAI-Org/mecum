//
//  ModelProvider+InApp.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports

extension ModelProvider {

    /// The providers the app offers: the two command line agents, which answer a worker with its
    /// tools, then Anthropic with an API key and Ollama, which answer through Mecum's own loop
    /// with the same tools when the model can call them. Settings, the connections sheet, the
    /// inspector's model list, the sidebar's count and the connection checks all read this list
    /// and nothing else.
    ///
    /// Gemini with an API key is left out for now: it cannot answer a worker until its transport
    /// has a tool turn for that loop. Its transport, keychain entry, settings page and connection
    /// check stay in place, and it comes back by adding it here once that turn exists.
    static let inApp: [ModelProvider] = [.codex, .claudeCode, .anthropic, .ollama]
}

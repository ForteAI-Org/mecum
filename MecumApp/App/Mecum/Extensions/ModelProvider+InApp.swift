//
//  ModelProvider+InApp.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports

extension ModelProvider {

    /// The providers the app offers: the two command line agents, which answer a worker with its
    /// tools, then Ollama, which answers through Mecum's own loop with the same tools when the
    /// model can call them. Settings, the connections sheet, the inspector's model list, the
    /// sidebar's count and the connection checks all read this list and nothing else.
    ///
    /// Anthropic and Gemini with an API key are left out for now: they cannot answer a worker
    /// until their transports have a tool turn for that loop. Their transports, keychain entries,
    /// settings pages and connection checks stay in place, and they come back by adding them
    /// here once it exists.
    static let inApp: [ModelProvider] = [.codex, .claudeCode, .ollama]
}

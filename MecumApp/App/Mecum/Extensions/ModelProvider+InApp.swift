//
//  ModelProvider+InApp.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports

extension ModelProvider {

    /// The providers the app offers: the two command line agents, which answer a worker with its
    /// tools. Settings, the connections sheet, the inspector's model list, the sidebar's count and
    /// the connection checks all read this list and nothing else.
    ///
    /// Anthropic and Gemini with an API key, and Ollama, are left out for now: none of them can
    /// answer a worker yet, since the text-only turn over their transports is not built. Their
    /// transports, keychain entries, settings pages and connection checks stay in place, and they
    /// come back by adding them here once that turn exists.
    static let inApp: [ModelProvider] = [.codex, .claudeCode]
}

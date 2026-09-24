//
//  SettingsPane.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports

/// SettingsPane is one page of Settings, as its sidebar lists them: the app's
/// own pages first, then what a worker needs to use this Mac, then one page
/// per provider.
enum SettingsPane: Hashable, Identifiable {
    case general
    case sidebar
    case chat
    case computer
    case virtualDisplay
    case provider(ModelProvider)

    static let appPanes: [SettingsPane] = [
        .general,
        .sidebar,
        .chat,
    ]

    static let computerPanes: [SettingsPane] = [
        .computer,
        .virtualDisplay,
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .general            : "General"
        case .sidebar            : "Sidebar"
        case .chat               : "Chat"
        case .computer           : "This Mac"
        case .virtualDisplay     : "Virtual Display"
        case .provider(let model): model.title
        }
    }

    var symbol: String {
        switch self {
        case .general       : "gearshape"
        case .sidebar       : "sidebar.left"
        case .chat          : "bubble.left.and.bubble.right"
        case .computer      : "desktopcomputer"
        case .virtualDisplay: "display"
        case .provider(let provider):
            switch provider {
            case .codex, .claudeCode: "terminal"
            case .anthropic, .gemini: "cloud"
            case .ollama            : "server.rack"
            }
        }
    }
}

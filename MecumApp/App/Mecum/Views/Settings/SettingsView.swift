//
//  SettingsView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

/// One tab per provider: access (sign-in state or API key), the model list
/// the composer's picker shows, and Ollama's knobs. The + button proposes the
/// models the provider itself reports.
struct SettingsView: View {

    @Bindable
    var store: ModelSettingsStore

    var body: some View {
        TabView {
            ForEach(ModelProvider.allCases) { provider in
                ProviderTab(
                    store   : store,
                    provider: provider
                )
                .tabItem {
                    Label(
                        provider.title,
                        systemImage: icon(provider)
                    )
                }
            }
        }
        .frame(
            width : 560,
            height: 520
        )
        .padding()
        // Every tab is a connection's status and a model list, so opening Settings asks for the checks.
        .task { store.refresh() }
    }

    private func icon(_ provider: ModelProvider) -> String {
        switch provider {
            case .codex, .claudeCode: "terminal"
            case .anthropic, .gemini: "key"
            case .ollama            : "desktopcomputer"
        }
    }
}

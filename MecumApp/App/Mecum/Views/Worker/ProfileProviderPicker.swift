//
//  ProfileProviderPicker.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// The profile's provider picker, every provider with its last known state
/// and how a worker on it answers.
struct ProfileProviderPicker: View {

    let connections: ModelSettingsStore

    @Binding var provider: ModelProvider?

    var body: some View {
        Picker(
            "Provider",
            selection: $provider
        ) {
            Text("Choose a provider").tag(ModelProvider?.none)
            ForEach(ModelProvider.allCases) { choice in
                Text(label(for: choice)).tag(Optional(choice))
            }
        }
    }

    /// The provider's name, its last known state, and how a worker on it answers.
    private func label(for provider: ModelProvider) -> String {
        var parts = [provider.title]
        if let state = connections.states[provider] { parts.append(state.title) }

        switch WorkerAnswer(provider: provider) {
        case .agent:  parts.append("answers as an agent")
        case .notYet: parts.append("does not answer yet")
        }
        return parts.joined(separator: " · ")
    }
}

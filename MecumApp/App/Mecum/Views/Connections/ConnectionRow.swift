//
//  ConnectionRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionRow is a connection's own row in the Connections sheet: the kind
/// of access as a symbol, the provider and one word for how it is reached,
/// then its state as a badge and the chevron that opens what acts on it.
struct ConnectionRow: View {

    let connections: ModelSettingsStore
    let provider   : ModelProvider

    let isOpen: Bool
    let toggle: () -> Void

    private var authentication: ProviderConnection.Authentication {
        ProviderConnection(
            provider: provider,
            settings: connections.providerSettings
        ).authentication
    }

    /// Where the provider's name starts, past the symbol, which the rows it opens line up with.
    static let textInset: CGFloat = 34

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.textInset - 10)
                    .accessibilityHidden(true)

                VStack(
                    alignment: .leading,
                    spacing  : 2
                ) {
                    Text(provider.title)

                    Text(reach)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ConnectionStateBadge(
                    state     : connections.states[provider],
                    isChecking: connections.isChecking(provider)
                )

                DisclosureChevron(isOpen: isOpen)
            }
            .padding(
                .vertical,
                4
            )
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }

    private var symbol: String {
        switch authentication {
        case .signedInCommandLine: "terminal"
        case .apiKey             : "cloud"
        case .localServer        : "server.rack"
        }
    }

    private var reach: String {
        switch authentication {
        case .signedInCommandLine: "Subscription"
        case .apiKey             : "API key"
        case .localServer        : "On this Mac"
        }
    }
}

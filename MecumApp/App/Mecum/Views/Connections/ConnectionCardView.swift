//
//  ConnectionCardView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionCardView is one connection as a card, inside a worker's profile:
/// name, type, destination, state and last check, and `ConnectionActions`
/// under them. The connections sheet shows the same connection as a block of
/// its form (`ConnectionSection`).
///
/// Each state has its own symbol, tint and sentence, so an absent key, a
/// refused one, a server that is down, a usage limit and a removed model do
/// not read as one red line. The sentence is `ConnectionState.message`, the
/// one the lab's Settings shows too.
struct ConnectionCardView: View {

    let connections: ModelSettingsStore
    let provider   : ModelProvider

    private var connection: ProviderConnection {
        ProviderConnection(
            provider: provider,
            settings: connections.providerSettings
        )
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 10
        ) {
            Text(connection.name)
                .font(.headline)

            stateLine

            Grid(
                alignment        : .leading,
                horizontalSpacing: 12,
                verticalSpacing  : 4
            ) {
                row(
                    "Type",
                    connection.authentication.title
                )
                row(
                    "Destination",
                    connection.destination
                )
                row(
                    "Last check",
                    lastCheck
                )
                // No connection here has a source that reports a balance or a price, and a
                // subscription exposes no per-token cost, so nothing is estimated either.
                row(
                    "Credits and cost",
                    "Non disponibile"
                )
            }
            .font(.callout)

            ConnectionActions(
                connections: connections,
                provider   : provider
            )
        }
        .padding(14)
        .frame(
            maxWidth : .infinity,
            alignment: .leading
        )
        .background(
            .background.secondary,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: State

    @ViewBuilder
    private var stateLine: some View {
        if let state = connections.states[provider] {
            VStack(
                alignment: .leading,
                spacing  : 4
            ) {
                Label(
                    state.title,
                    systemImage: Self.symbol(state)
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(Self.tint(state))

                if !state.isReady {
                    Text(state.message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(
                            horizontal: false,
                            vertical  : true
                        )
                }
            }
            .accessibilityElement(children: .combine)
        } else if connections.isChecking(provider) {
            Text("Checking…")
                .font(.callout)
                .shimmering()
        } else {
            Label(
                "Not checked yet",
                systemImage: "circle.dashed"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var lastCheck: String {
        guard let date = connections.checkedAt[provider] else { return "Never" }

        return date.formatted(
            date: .omitted,
            time: .standard
        )
    }

    private static func symbol(_ state: ConnectionState) -> String {
        switch state {
        case .ready:              "checkmark.circle.fill"
        case .credentialMissing:  "key.slash"
        case .credentialRejected: "xmark.shield"
        case .unreachable:        "network.slash"
        case .usageLimited:       "hourglass"
        case .modelRemoved:       "questionmark.square.dashed"
        case .refused:            "hand.raised"
        }
    }

    private static func tint(_ state: ConnectionState) -> Color {
        switch state {
        case .ready:              .green
        case .credentialMissing:  .secondary
        case .credentialRejected: .red
        case .unreachable:        .orange
        case .usageLimited:       .yellow
        case .modelRemoved:       .purple
        case .refused:            .red
        }
    }

    // MARK: Helpers

    private func row(
        _ label: String,
        _ value: String
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

//
//  ConnectionItem.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionItem is one connection in the Connections sheet: its row, and
/// while the row is open the rows that act on it, each a row of the form so
/// the rows below move as they come in. What is wrong comes first, then what
/// the connection needs: a key, a sign-in, an address, and the check. They
/// start where the provider's name does, so they read as the connection's own.
struct ConnectionItem: View {

    let connections: ModelSettingsStore
    let provider   : ModelProvider

    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        ConnectionRow(
            connections: connections,
            provider   : provider,
            isOpen     : isOpen,
            toggle     : toggle
        )

        if isOpen {
            Group {
                if let state = connections.states[provider], !state.isReady {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.message)
                        if let detail = state.technicalDetail {
                            Text("Details: \(detail)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(
                        horizontal: false,
                        vertical  : true
                    )
                }

                ConnectionActions(
                    connections: connections,
                    provider   : provider,
                    note       : lastCheck
                )
            }
            .padding(
                .leading,
                ConnectionRow.textInset
            )
        }
    }

    /// When the last check finished, or nil before the first, which the row's badge already says.
    private var lastCheck: String? {
        connections.checkedAt[provider].map { date in
            let time = date.formatted(
                date: .omitted,
                time: .shortened
            )
            return "Checked at \(time)"
        }
    }
}

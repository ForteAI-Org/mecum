//
//  ConnectionSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionSection is one connection as a block of the connections sheet's
/// grouped form (§7.3): the provider's name with how it is authenticated under
/// it and its state at the trailing edge, then where it sends, and last what
/// can be done to it, beside when it was last checked.
///
/// The state is a `StatusText`, the inspector's dot and words: green for
/// ready, orange for a usage limit or a check under way, red for a refusal or
/// an unreachable destination, grey for no credential yet. When it is not
/// ready, `ConnectionState.message` says why and what to do, under the state,
/// so an absent key, a refused one, a server that is down, a usage limit and
/// a removed model do not read as one red line. A local server's destination
/// is the address it is edited in, so it has no row of its own.
struct ConnectionSection: View {

    let connections: ModelSettingsStore
    let provider   : ModelProvider

    private var connection: ProviderConnection {
        ProviderConnection(provider: provider, settings: connections.providerSettings)
    }

    var body: some View {
        Section {
            LabeledContent {
                status
            } label: {
                Text(connection.name)
                    .font(.headline)
                Text(connection.authentication.title)
            }
            if let state = connections.states[provider], !state.isReady {
                Text(state.message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if connection.authentication != .localServer {
                LabeledContent("Destination") {
                    Text(connection.destination)
                        .textSelection(.enabled)
                }
            }
            ConnectionActions(connections: connections, provider: provider, note: lastCheck)
        }
    }

    @ViewBuilder
    private var status: some View {
        if connections.isChecking(provider) {
            StatusText("Checking…", tone: .waiting)
        } else if let state = connections.states[provider] {
            StatusText(state.title, tone: Self.tone(state))
        } else {
            StatusText("Not checked yet", tone: .quiet)
        }
    }

    /// When the last check finished, or nil before the first, which the state already says.
    private var lastCheck: String? {
        connections.checkedAt[provider].map { "Checked at \($0.formatted(date: .omitted, time: .shortened))" }
    }

    private static func tone(_ state: ConnectionState) -> StatusText.Tone {
        switch state {
        case .ready:             .ready
        case .credentialMissing: .quiet
        case .usageLimited:      .waiting
        case .credentialRejected, .unreachable, .modelRemoved, .refused:
            .trouble
        }
    }
}

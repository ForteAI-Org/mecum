//
//  ConnectionCardView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionCardView is one connection as §7.3 lays it out: name, type,
/// destination, state and last check, with connect, verify, replace
/// credential and disconnect.
///
/// Each state has its own symbol, tint and sentence, so an absent key, a
/// refused one, a server that is down, a usage limit and a removed model do
/// not read as one red line. The sentence is `ConnectionState.message`, the
/// one the lab's Settings shows too.
///
/// A key is typed into a secure field, handed to the keychain and cleared from
/// the field. The card never shows a key back.
struct ConnectionCardView: View {

    let connections: ModelSettingsStore
    let provider   : ModelProvider

    @State private var enteredKey  = ""
    @State private var isReplacing = false
    @State private var address     = ""

    private var connection: ProviderConnection {
        ProviderConnection(provider: provider, settings: connections.providerSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(connection.name)
                .font(.headline)

            stateLine

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Type", connection.authentication.title)
                row("Destination", connection.destination)
                row("Last check", lastCheck)
                // No connection here has a source that reports a balance or a price, and a
                // subscription exposes no per-token cost, so nothing is estimated either.
                row("Credits and cost", "Non disponibile")
            }
            .font(.callout)

            if let failure = connections.credentialFailure[provider] {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { address = connections.ollamaHost }
    }

    // MARK: State

    @ViewBuilder
    private var stateLine: some View {
        if let state = connections.states[provider] {
            VStack(alignment: .leading, spacing: 4) {
                Label(state.title, systemImage: Self.symbol(state))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Self.tint(state))
                if !state.isReady {
                    Text(state.message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        } else if connections.isChecking(provider) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.callout)
            }
        } else {
            Label("Not checked yet", systemImage: "circle.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var lastCheck: String {
        guard let date = connections.checkedAt[provider] else { return "Never" }
        return date.formatted(date: .omitted, time: .standard)
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

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch connection.authentication {
        case .apiKey:              keyActions
        case .signedInCommandLine: commandLineActions
        case .localServer:         localServerActions
        }
    }

    @ViewBuilder
    private var keyActions: some View {
        if !connections.hasCredential(provider) || isReplacing {
            HStack(spacing: 8) {
                SecureField("API key", text: $enteredKey, prompt: Text("Paste the key"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                Button(connections.hasCredential(provider) ? "Replace credential" : "Connect", action: saveKey)
                    .disabled(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isReplacing {
                    Button("Cancel") {
                        enteredKey  = ""
                        isReplacing = false
                    }
                }
            }
            HStack(spacing: 12) {
                Text("Kept in your keychain and sent only to \(connection.destination).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let url = provider.consoleURL {
                    Link("Get a key…", destination: url).font(.caption)
                }
            }
        } else {
            HStack(spacing: 8) {
                verifyButton
                Button("Replace credential") { isReplacing = true }
                Button("Disconnect", role: .destructive) { connections.setCredential("", for: provider) }
                    .help("Removes the key from your keychain. Workers keep their model and cannot answer until a key is back.")
            }
        }
    }

    @ViewBuilder
    private var commandLineActions: some View {
        Text(provider.accessHint)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            verifyButton
            Text("Signed in outside this app, so the sign-in is replaced or removed in Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var localServerActions: some View {
        HStack(spacing: 8) {
            TextField("Address", text: $address, prompt: Text("http://127.0.0.1:11434"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveAddress)
            Button("Connect", action: saveAddress)
                .disabled(address == connections.ollamaHost || address.isEmpty)
            verifyButton
        }
        Text("A server on this Mac needs no credential.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var verifyButton: some View {
        Button("Verify") { connections.refresh([provider]) }
            .disabled(connections.isChecking(provider))
    }

    // MARK: Helpers

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func saveKey() {
        let key = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        connections.setCredential(key, for: provider)
        enteredKey  = ""
        isReplacing = false
    }

    private func saveAddress() {
        guard !address.isEmpty else { return }
        connections.ollamaHost = address
    }
}

//
//  ConnectionActions.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionActions is what can be done to one connection (§7.3): connect,
/// check, replace the credential and disconnect, as its kind of
/// authentication allows, with the buttons at the trailing edge.
///
/// The body is several rows, so a grouped form gives each its own line and a
/// card stacks them. A key is typed into a secure field, handed to the
/// keychain and cleared from the field; nothing here shows a key back. A
/// subscription is signed in outside this app, so only its check is here, with
/// how to sign in while it is not ready. A local server needs an address and
/// no credential.
struct ConnectionActions: View {

    let connections: ModelSettingsStore
    let provider   : ModelProvider

    /// Words for the leading edge of the row of buttons, such as when the
    /// connection was last checked; nil leaves it empty.
    let note: String?

    @State private var enteredKey  = ""
    @State private var isReplacing = false
    @State private var address     : String

    init(
        connections: ModelSettingsStore,
        provider   : ModelProvider,
        note       : String? = nil
    ) {
        self.connections = connections
        self.provider    = provider
        self.note        = note
        _address         = State(initialValue: connections.ollamaHost)
    }

    private var connection: ProviderConnection {
        ProviderConnection(
            provider: provider,
            settings: connections.providerSettings
        )
    }

    var body: some View {
        if let failure = connections.credentialFailure[provider] {
            Label(
                failure,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(
                horizontal: false,
                vertical  : true
            )
        }

        switch connection.authentication {
        case .apiKey:              keyActions
        case .signedInCommandLine: commandLineActions
        case .localServer:         localServerActions
        }
    }

    // MARK: Kinds

    @ViewBuilder
    private var keyActions: some View {
        if !connections.hasCredential(provider) || isReplacing {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    SecureField(
                        "API key",
                        text  : $enteredKey,
                        prompt: Text("Paste the key")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)

                    if isReplacing {
                        Button("Cancel") {
                            enteredKey  = ""
                            isReplacing = false
                        }
                    }

                    Button(
                        isReplacing ? "Replace" : "Connect",
                        action: saveKey
                    )
                    .disabled(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 12) {
                secondary("Kept in your keychain and sent only to \(connection.destination).")

                Spacer(minLength: 0)

                if let url = provider.consoleURL {
                    Link(
                        "Get a key…",
                        destination: url
                    )
                    .font(.callout)
                }
            }
        } else {
            buttons {
                Button(
                    "Disconnect",
                    role: .destructive
                ) {
                    connections.setCredential(
                        "",
                        for: provider
                    )
                }
                .help("Removes the key from your keychain. Workers keep their model and cannot answer "
                    + "until a key is back.")

                Button("Replace Key…") { isReplacing = true }

                checkButton
            }
        }
    }

    @ViewBuilder
    private var commandLineActions: some View {
        if connections.states[provider]?.isReady != true {
            secondary(provider.accessHint)
        }

        buttons { checkButton }
    }

    @ViewBuilder
    private var localServerActions: some View {
        LabeledContent("Address") {
            HStack(spacing: 8) {
                TextField(
                    "Address",
                    text  : $address,
                    prompt: Text("http://127.0.0.1:11434")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveAddress)

                Button(
                    "Connect",
                    action: saveAddress
                )
                .disabled(address == connections.ollamaHost || address.isEmpty)
            }
        }

        buttons { checkButton }
    }

    // MARK: Parts

    /// The note at the leading edge and `content` at the trailing one.
    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            if let note { secondary(note) }

            Spacer(minLength: 0)

            content()
        }
    }

    private var checkButton: some View {
        Button("Check") { connections.refresh([provider]) }
            .disabled(connections.isChecking(provider))
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(
                horizontal: false,
                vertical  : true
            )
    }

    private func saveKey() {
        let key = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        connections.setCredential(
            key,
            for: provider
        )
        enteredKey  = ""
        isReplacing = false
    }

    private func saveAddress() {
        guard !address.isEmpty else { return }

        connections.ollamaHost = address
    }
}

//
//  ModelListSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

/// The favorite models as a list: trash per row, + proposes what the
/// provider reports or takes a custom name.
struct ModelListSection: View {

    @Bindable
    var store: ModelSettingsStore

    let provider: ModelProvider

    @State
    private var discovered    : [String] = []
    @State
    private var discoveryError: String?
    @State
    private var isDiscovering            = false
    @State
    private var customName               = ""
    @State
    private var showsCustomField         = false

    var body: some View {
        Section {
            let models = store.models(for: provider)
            if models.isEmpty {
                Text("No models yet. Use + to add the ones you want in the picker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(
                models,
                id: \.self
            ) { model in
                HStack {
                    Text(model)
                        .font(.system(
                            .body,
                            design: .monospaced
                        ))
                    Spacer()
                    Button {
                        store.remove(
                            model,
                            from: provider
                        )
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove from the picker")
                }
            }
            if showsCustomField {
                HStack {
                    TextField(
                        "Model name",
                        text: $customName
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(
                        .body,
                        design: .monospaced
                    ))
                    .onSubmit(addCustom)
                    Button(
                        "Add",
                        action: addCustom
                    )
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { showsCustomField = false; customName = "" }
                }
            }
            if let discoveryError {
                Text(discoveryError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Models in the picker")
                Spacer()
                Menu {
                    let missing = discovered.filter { !store.models(for: provider).contains($0) }
                    if isDiscovering {
                        Text("Loading…")
                    } else if missing.isEmpty {
                        Text(discovered.isEmpty ? "Nothing found yet" : (canDiscover ? "All found models are listed" : "All known models are listed"))
                    } else {
                        Section(canDiscover ? "Reported by \(provider.title)" : "Known models") {
                            ForEach(
                                missing,
                                id: \.self
                            ) { model in
                                Button(model) {
                                    store.add(
                                        model,
                                        to: provider
                                    )
                                }
                            }
                        }
                    }
                    Divider()
                    // The CLIs expose no model listing; their list is the known set.
                    if canDiscover {
                        Button("Refresh from \(provider.title)…") { Task { await discover() } }
                    }
                    Button("Add custom name…") { showsCustomField = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a model")
            }
        }
        .task(id: discoveryKey) { await discover() }
    }

    /// Codex and Claude Code have no model-listing command.
    private var canDiscover: Bool { provider != .codex && provider != .claudeCode }

    /// Re-discovers when the key or the server changes.
    private var discoveryKey: String {
        switch provider {
            case .anthropic         : store.anthropicAPIKey
            case .gemini            : store.geminiAPIKey
            case .ollama            : store.ollamaHost
            case .codex, .claudeCode: "cli"
        }
    }

    private func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            discovered     = try await store.discoverModels(for: provider)
            discoveryError = nil
        } catch {
            discovered     = []
            discoveryError = error.localizedDescription
        }
    }

    private func addCustom() {
        store.add(
            customName,
            to: provider
        )
        customName       = ""
        showsCustomField = false
    }
}

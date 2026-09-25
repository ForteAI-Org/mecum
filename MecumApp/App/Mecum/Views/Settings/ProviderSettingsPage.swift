//
//  ProviderSettingsPage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports
import SwiftUI

/// ProviderSettingsPage is one provider's page of Settings: its connection,
/// with what is wrong and what it needs (the key, the sign-in or the address),
/// the models its catalogue lists, and for Ollama how the local model
/// generates.
///
/// The connection's state is the light at the trailing end of the toolbar,
/// which checks it again when clicked and says when it was last checked under
/// the pointer, so the page does not say it again. A subscription that works
/// has nothing else to show, and then the page has no Connection section.
struct ProviderSettingsPage: View {

    let store   : ModelSettingsStore
    let provider: ModelProvider

    @State private var isListing     = false
    @State private var listingFailed = false

    var body: some View {
        Form {
            if hasConnectionRows {
                Section("Connection") {
                    if let state = store.states[provider], !state.isReady {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(state.message(for: provider))
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
                        connections: store,
                        provider   : provider,
                        checks     : false
                    )
                }
            }

            Section {
                models
            } header: {
                HStack {
                    Text("Models")

                    Spacer()

                    Button(action: refreshModels) {
                        Label(
                            "Refresh Models",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh models.")
                    .disabled(isListing || store.states[provider]?.isReady != true)
                }
            } footer: {
                Text("Choose each worker’s model and Effort in the conversation composer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if provider == .ollama {
                OllamaGenerationSection(store: store)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { statusLight }
        }
    }

    // MARK: Parts

    private var statusLight: some View {
        Button {
            store.refresh([provider])
        } label: {
            ConnectionStateBadge(
                state     : store.states[provider],
                isChecking: store.isChecking(provider),
                glows     : true,
                help      : statusHelp
            )
        }
        .help(statusHelp)
        .accessibilityLabel(statusWords)
        .accessibilityHint("Checks the connection again")
    }

    /// The state, when it was checked, and the available action.
    private var statusHelp: String {
        [statusWords, lastCheck, "Check the connection again"]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    /// Whether the Connection section has anything to say: a subscription
    /// that works needs neither a message nor an action.
    private var hasConnectionRows: Bool {
        let connection = ProviderConnection(
            provider: provider,
            settings: store.providerSettings
        )
        return connection.authentication != .signedInCommandLine || store.states[provider]?.isReady != true
    }

    @ViewBuilder
    private var models: some View {
        if isListing {
            Text("Loading models…")
                .foregroundStyle(.secondary)
                .shimmering()
        } else if let catalogue = store.catalogues[provider], !catalogue.isEmpty {
            ForEach(catalogue) { model in
                LabeledContent(model.title) {
                    Text(levels(of: model))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(listingFailed ? "Couldn’t load models from \(provider.title)." : "Models appear after the connection succeeds.")
                .foregroundStyle(.secondary)
        }
    }

    /// The efforts a model takes, as its lowest and highest level.
    private func levels(of model: ModelInfo) -> String {
        guard let lowest = model.efforts.first, let highest = model.efforts.last else { return "No Effort Levels" }

        return lowest == highest
            ? lowest.title(for: provider)
            : "\(lowest.title(for: provider)) to \(highest.title(for: provider))"
    }

    private var statusWords: String {
        if store.isChecking(provider) { return "Checking…" }
        return store.states[provider]?.title ?? "Not checked yet"
    }

    /// When the last check finished, or nil before the first, which the status already says.
    private var lastCheck: String? {
        store.checkedAt[provider].map { date in
            let time = date.formatted(
                date: .omitted,
                time: .shortened
            )
            return "Checked at \(time)"
        }
    }

    private func refreshModels() {
        isListing = true
        Task {
            defer { isListing = false }

            do {
                _ = try await store.loadCatalogue(for: provider)
                listingFailed = false
            } catch {
                listingFailed = true
            }
        }
    }
}

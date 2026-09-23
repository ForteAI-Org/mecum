//
//  WorkerProfileSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI
import Workspace

/// WorkerProfileSheet is the Model and connection area of a worker's profile
/// (§6.3): provider, model and reasoning effort, edited as a draft with Save
/// and Cancel and written through `configure` as a new version.
///
/// It stays a sheet, opened from the inspector and the worker's commands; the
/// other three areas of the profile are not built yet.
///
/// Every provider is offered. One with no agent in this build is marked so in
/// the picker and explained the moment it is chosen, in `WorkerAnswer`'s
/// reason, and saving it stays possible with that said.
/// A model the catalogue dropped is shown with a proposed replacement that the
/// person applies; nothing replaces it for them (§7.4). A change between local
/// and cloud, or between a subscription and a metered key, asks first.
struct WorkerProfileSheet: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    @Environment(\.dismiss)
    private var dismiss

    @State private var provider: ModelProvider?
    @State private var model   : String
    @State private var effort  : ReasoningEffort

    @State private var catalogue         : [String] = []
    @State private var isLoadingCatalogue = false
    @State private var catalogueFailed    = false

    /// The sentence to consent to before a save that moves the worker.
    @State private var consent: String?

    init(team: TeamModel, worker: WorkerSnapshot) {
        self.team   = team
        self.worker = worker
        _provider   = State(initialValue: worker.configuration?.provider)
        _model      = State(initialValue: worker.configuration?.model ?? "")
        _effort     = State(initialValue: worker.configuration?.effort ?? .medium)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    providerPicker
                    if let provider {
                        if let refusal = WorkerAnswer(provider: provider).refusal {
                            deadEnd(provider, refusal)
                        }
                        ConnectionCardView(connections: team.connections, provider: provider)
                        modelPicker(provider)
                        if let removed = removedModel {
                            proposal(removed, provider)
                        }
                        EffortControl(scale: EffortScale(provider: provider, model: model), effort: $effort)
                    }
                }
                .padding(.vertical, 2)
            }

            Text("Changes apply from the next turn. Answers already given keep the model that produced them.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 540, height: 680)
        // A model picker appearing is what asks for the checks, and for this worker's model.
        .task {
            team.connections.refresh()
            await team.checkModel(of: worker.id)
        }
        .task(id: provider) { await loadCatalogue() }
        .onChange(of: model) { clampEffort() }
        .confirmationDialog(
            "Change where \(worker.name) runs?",
            isPresented: Binding(get: { consent != nil }, set: { if !$0 { consent = nil } }),
            presenting : consent
        ) { _ in
            Button("Change model") { commit() }
            Button("Cancel", role: .cancel) {}
        } message: { sentence in
            Text(sentence)
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            MascotView(appearance: worker.appearance, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(worker.name).font(.title3.bold())
                Text("Model and connection").foregroundStyle(.secondary)
            }
            Spacer()
            if let version = worker.configurationVersion {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var providerPicker: some View {
        Picker("Provider", selection: $provider) {
            Text("Choose a provider").tag(ModelProvider?.none)
            ForEach(ModelProvider.allCases) { choice in
                Text(label(for: choice)).tag(Optional(choice))
            }
        }
    }

    private func deadEnd(_ provider: ModelProvider, _ refusal: String) -> some View {
        Label(
            """
            \(provider.title) does not answer here yet: \(refusal). A worker saved with it stays \
            on the team and will not answer. Choose Claude Code or Codex for a worker that answers.
            """,
            systemImage: "exclamationmark.bubble"
        )
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func modelPicker(_ provider: ModelProvider) -> some View {
        if isLoadingCatalogue {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the catalogue…")
            }
        } else if modelOptions.isEmpty {
            Text(
                catalogueFailed
                    ? "The catalogue could not be read, so there is no model to choose. The connection above says why."
                    : "\(provider.title) lists no model. For Ollama, pull one with “ollama pull <name>”."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Picker("Model", selection: $model) {
                if model.isEmpty { Text("Choose a model").tag("") }
                ForEach(modelOptions, id: \.self) { option in
                    Text(catalogue.contains(option) ? option : "\(option) (not listed)").tag(option)
                }
            }
        }
    }

    private func proposal(_ removed: String, _ provider: ModelProvider) -> some View {
        let replacement = ProviderCatalog.replacement(for: removed, provider: provider, catalogue: catalogue)
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                """
                \(removed) is no longer in \(provider.title)'s catalogue, so \(worker.name) needs \
                configuring. Nothing was changed.
                """,
                systemImage: "questionmark.square.dashed"
            )
            .fixedSize(horizontal: false, vertical: true)
            if let replacement {
                Button("Use \(replacement) instead") { model = replacement }
                    .help("Puts it in the draft. Nothing is saved until you press Save.")
            }
        }
        .padding(10)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: State

    private func connection(_ provider: ModelProvider) -> ProviderConnection {
        ProviderConnection(provider: provider, settings: team.connections.providerSettings)
    }

    /// The provider's name, its last known state, and how a worker on it answers.
    private func label(for provider: ModelProvider) -> String {
        var parts = [provider.title]
        if let state = team.connections.states[provider] { parts.append(state.title) }
        switch WorkerAnswer(provider: provider) {
        case .agent:  parts.append("answers as an agent")
        case .notYet: parts.append("does not answer yet")
        }
        return parts.joined(separator: " · ")
    }

    /// The catalogue, and the draft's model when the catalogue does not list it.
    private var modelOptions: [String] {
        catalogue.contains(model) || model.isEmpty ? catalogue : [model] + catalogue
    }

    /// The saved model, when the typed check found it gone and the draft still holds it.
    private var removedModel: String? {
        guard case .modelRemoved(let removed) = team.modelStates[worker.id],
              worker.configuration?.provider == provider,
              removed == model
        else { return nil }
        return removed
    }

    private var draft: ModelSelection? {
        guard let provider, !model.isEmpty else { return nil }
        return ModelSelection(provider: provider, model: model, effort: effort)
    }

    private var canSave: Bool {
        guard let draft else { return false }
        return draft != worker.configuration
    }

    private func loadCatalogue() async {
        guard let provider else {
            catalogue = []
            return
        }
        isLoadingCatalogue = true
        defer { isLoadingCatalogue = false }
        do {
            catalogue       = try await team.connections.discoverModels(for: provider)
            catalogueFailed = false
        } catch {
            // The reason is the connection card's to state, from the typed check.
            catalogue       = []
            catalogueFailed = true
        }
        guard self.provider == provider, !catalogue.contains(model) else { return clampEffort() }
        // Back on the saved provider the saved model returns, even one the catalogue dropped.
        if let saved = worker.configuration, saved.provider == provider {
            model = saved.model
        } else {
            model = provider.defaultModels.first(where: catalogue.contains) ?? catalogue.first ?? ""
        }
        clampEffort()
    }

    /// Keeps the draft's effort on a detent the chosen model has.
    private func clampEffort() {
        guard let provider else { return }
        let scale = EffortScale(provider: provider, model: model)
        guard !scale.isEmpty, scale.index(of: effort) == nil else { return }
        effort = scale.positions.contains(.medium) ? .medium : (scale.positions.last ?? effort)
    }

    // MARK: Saving

    private func save() {
        guard let draft else { return }
        if let previous = worker.configuration?.provider,
           let sentence = connection(draft.provider).consentNeeded(movingFrom: connection(previous)) {
            consent = sentence
            return
        }
        commit()
    }

    private func commit() {
        guard let draft else { return }
        dismiss()
        Task { await team.configure(worker.id, selection: draft) }
    }
}

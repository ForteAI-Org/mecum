//
//  WorkerProfileSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

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

    init(
        team  : TeamModel,
        worker: WorkerSnapshot
    ) {
        self.team   = team
        self.worker = worker
        _provider   = State(initialValue: worker.configuration?.provider)
        _model      = State(initialValue: worker.configuration?.model ?? "")
        _effort     = State(initialValue: worker.configuration?.effort ?? .medium)
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 16
        ) {
            ProfileHeader(worker: worker)

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing  : 16
                ) {
                    ProfileProviderPicker(
                        connections: team.connections,
                        provider   : $provider
                    )

                    if let provider {
                        if let refusal = WorkerAnswer(provider: provider).refusal {
                            ProfileDeadEnd(
                                provider: provider,
                                refusal : refusal
                            )
                        }

                        ConnectionCardView(
                            connections: team.connections,
                            provider   : provider
                        )

                        ProfileModelPicker(
                            provider          : provider,
                            model             : $model,
                            catalogue         : catalogue,
                            isLoadingCatalogue: isLoadingCatalogue,
                            catalogueFailed   : catalogueFailed
                        )

                        if let removed = removedModel {
                            ProfileModelProposal(
                                removed   : removed,
                                provider  : provider,
                                workerName: worker.name,
                                catalogue : catalogue,
                                model     : $model
                            )
                        }

                        EffortControl(
                            scale : EffortScale(
                                provider: provider,
                                model   : model
                            ),
                            effort: $effort
                        )
                    }
                }
                .padding(
                    .vertical,
                    2
                )
            }

            Text("Changes apply from the next turn. Answers already given keep the model that produced them.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button(
                    "Cancel",
                    role: .cancel
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(
                    "Save",
                    action: save
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(
            width : 540,
            height: 680
        )
        // A model picker appearing is what asks for the checks, and for this worker's model.
        .task {
            team.connections.refresh()
            await team.checkModel(of: worker.id)
        }
        .task(id: provider) { await loadCatalogue() }
        .onChange(of: model) { clampEffort() }
        .confirmationDialog(
            "Change where \(worker.name) runs?",
            isPresented: Binding(
                get: { consent != nil },
                set: { if !$0 { consent = nil } }
            ),
            presenting : consent
        ) { _ in
            Button("Change model") { commit() }
            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: { sentence in
            Text(sentence)
        }
    }

    // MARK: State

    private func connection(_ provider: ModelProvider) -> ProviderConnection {
        ProviderConnection(
            provider: provider,
            settings: team.connections.providerSettings
        )
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

        return ModelSelection(
            provider: provider,
            model   : model,
            effort  : effort
        )
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

        let scale = EffortScale(
            provider: provider,
            model   : model
        )
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
        Task {
            await team.configure(
                worker.id,
                selection: draft
            )
        }
    }
}

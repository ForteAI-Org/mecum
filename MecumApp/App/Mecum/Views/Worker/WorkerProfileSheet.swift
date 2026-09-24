//
//  WorkerProfileSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// WorkerProfileSheet is the Provider and connection area of a worker's profile
/// (§6.3): the provider, edited as a draft with Save and Cancel and written
/// through `configure` as a new version. The model and the effort are chosen
/// in the composer's popup; here the model follows the provider, its default
/// from the provider's catalogue, and is shown and not edited.
///
/// It stays a sheet, opened from the inspector and the worker's commands; the
/// other three areas of the profile are not built yet.
///
/// Every provider is offered. One with no agent in this build is marked so in
/// the picker and explained the moment it is chosen, in `WorkerAnswer`'s
/// reason, and saving it stays possible with that said.
/// A change between local and cloud, or between a subscription and a metered
/// key, asks first.
struct WorkerProfileSheet: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    @Environment(\.dismiss)
    private var dismiss

    @State private var provider: ModelProvider?
    @State private var model   : String
    @State private var effort  : ReasoningEffort

    @State private var catalogue         : [ModelInfo] = []
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

                        modelLine
                    }
                }
                .padding(
                    .vertical,
                    2
                )
            }

            Text("""
                Changes apply from the next turn. Answers already given keep the model that produced them. \
                The model and the effort are changed from the message bar.
                """)
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

    /// The model the provider comes with, as a line; its catalogue's name when it has one.
    @ViewBuilder
    private var modelLine: some View {
        LabeledContent("Model") {
            if isLoadingCatalogue {
                Text("Listing models…")
                    .foregroundStyle(.secondary)
                    .shimmering()
            } else if model.isEmpty {
                Text(catalogueFailed ? "The provider could not list its models." : "The provider lists no models.")
                    .foregroundStyle(.secondary)
            } else {
                Text(catalogue.first { $0.id == model }?.title ?? model)
                    .foregroundStyle(.secondary)
            }
        }
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
            catalogue       = try await team.connections.loadCatalogue(for: provider)
            catalogueFailed = false
        } catch {
            // The reason is the connection card's to state, from the typed check.
            catalogue       = []
            catalogueFailed = true
        }
        guard self.provider == provider else { return }

        // Back on the saved provider the saved model and effort return, even a model the catalogue dropped.
        if let saved = worker.configuration, saved.provider == provider {
            model  = saved.model
            effort = saved.effort
            return
        }

        let ids    = catalogue.map(\.id)
        let chosen = provider.defaultModels.first(where: ids.contains).flatMap { id in catalogue.first { $0.id == id } }
            ?? catalogue.first
        model  = chosen?.id ?? ""
        effort = chosen.map(Self.startingEffort) ?? .medium
    }

    /// The level a model starts at: its catalogue's default, else medium, else its highest.
    private static func startingEffort(of model: ModelInfo) -> ReasoningEffort {
        model.defaultEffort
            ?? (model.efforts.contains(.medium) ? .medium : model.efforts.last ?? .medium)
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

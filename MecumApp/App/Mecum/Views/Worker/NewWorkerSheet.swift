//
//  NewWorkerSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SwiftUI

/// NewWorkerSheet creates one worker, by hand, in the Connections sheet's
/// language: a title, a grouped list, and a bar with Cancel and Create, the
/// default button.
///
/// The first group is the mascot that will be drawn, not an approximation of
/// it, with its colour as swatches and a new shape a click away. The second
/// is the worker's name, the only field required, its role and its
/// description; the name has the keyboard when the sheet opens.
///
/// The third is the provider, each with its connection's state, and the
/// model: the first ready provider and the model it comes with are chosen
/// already, so a name and Return make a worker that can answer. With no
/// provider ready, or no model listed, the worker is saved with no model
/// attached and is marked to configure, as a worker that cannot answer must
/// not look like one that can. The offscreen snapshot reads the catalogue
/// already held with `loadsCatalogue` off, since listing it runs the command
/// lines and reaches the network.
struct NewWorkerSheet: View {

    let team: TeamModel

    var loadsCatalogue = true

    @Environment(\.dismiss)
    private var dismiss

    @State private var name         = ""
    @State private var role         = ""
    @State private var instructions = ""
    @State private var appearance   = NewWorkerSheet.startingAppearance()
    @State private var provider     : ModelProvider?

    /// The chosen provider's models, nil while they are being listed.
    @State private var catalogue: [ModelInfo]?
    @State private var model    : String?

    @FocusState private var namesFirst: Bool

    init(
        team          : TeamModel,
        loadsCatalogue: Bool = true
    ) {
        self.team           = team
        self.loadsCatalogue = loadsCatalogue
        _provider           = State(initialValue: .preselected(in: team.connections.states))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Worker")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
                .padding(
                    .horizontal,
                    20
                )
                .padding(
                    .top,
                    20
                )

            Form {
                Section {
                    mascot
                }

                Section {
                    TextField(
                        "Name",
                        text  : $name,
                        prompt: Text("Worker name")
                    )
                    .focused($namesFirst)

                    TextField(
                        "Role",
                        text  : $role,
                        prompt: Text("Example: Researcher")
                    )

                    TextField(
                        "Instructions",
                        text  : $instructions,
                        prompt: Text("Describe responsibilities or constraints"),
                        axis  : .vertical
                    )
                    .lineLimit(2...5)
                }

                Section {
                    Picker(
                        "Provider",
                        selection: $provider
                    ) {
                        Text("Choose Later").tag(ModelProvider?.none)

                        Divider()

                        ForEach(ModelProvider.allCases) { provider in
                            Text(label(of: provider)).tag(Optional(provider))
                        }
                    }

                    modelRow
                } footer: {
                    Text("You can change the model later from the composer. Mecum asks for permission only when this worker first uses your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)

            Divider()

            HStack {
                Spacer()

                Button(
                    "Cancel",
                    role: .cancel
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(
                .horizontal,
                20
            )
            .padding(
                .vertical,
                14
            )
        }
        .frame(
            width : 460,
            height: 540
        )
        .onAppear { namesFirst = true }
        .task(id: provider) { await listModels() }
    }

    // MARK: Parts

    /// The mascot as it will be drawn, its colour and a new shape.
    private var mascot: some View {
        VStack(spacing: 14) {
            MascotView(
                appearance: appearance,
                size      : 72
            )

            HStack(spacing: 12) {
                MascotPalettePicker(selection: $appearance.palette)

                Divider()
                    .frame(height: 18)

                Button {
                    appearance.seed = Int64.random(in: Int64.min...Int64.max)
                } label: {
                    Label(
                        "New Shape",
                        systemImage: "dice"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Create a new shape and keep this color.")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(
            .vertical,
            8
        )
    }

    /// The chosen provider’s models, a small progress indicator while they are
    /// listed, and a few quiet words when there are none to choose.
    @ViewBuilder
    private var modelRow: some View {
        if provider != nil, let catalogue, !catalogue.isEmpty {
            Picker(
                "Model",
                selection: $model
            ) {
                ForEach(catalogue) { entry in
                    Text(entry.title).tag(Optional(entry.id))
                }
            }
        } else {
            LabeledContent("Model") {
                if let provider, catalogue == nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading \(provider.title) models")
                } else if let provider {
                    Text(unavailable(provider))
                        .foregroundStyle(.secondary)
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The provider's name and its connection's state, in the inspector's words.
    private func label(of provider: ModelProvider) -> String {
        let state = team.connections.states[provider]?.title
            ?? (team.connections.isChecking(provider) ? "Checking…" : "Not checked yet")
        return "\(provider.title) · \(state)"
    }

    /// Why a provider lists no model: its connection's trouble when it has one.
    private func unavailable(_ provider: ModelProvider) -> String {
        guard let state = team.connections.states[provider], !state.isReady else { return "No models available" }

        return state.title
    }

    /// Lists the chosen provider's models and picks the one it comes with.
    private func listModels() async {
        catalogue = nil
        model     = nil
        guard let provider else { return }

        let listed: [ModelInfo]?
        if loadsCatalogue {
            listed = try? await team.connections.loadCatalogue(for: provider)
        } else {
            listed = team.connections.catalogues[provider]
        }
        // Another provider was chosen meanwhile, and its own listing replaces this one.
        guard !Task.isCancelled else { return }

        catalogue = listed ?? []
        model     = provider.startingModel(in: listed ?? [])?.id
    }

    /// The provider and model chosen, at the model's starting effort; nil leaves the worker to configure.
    private var chosenSelection: ModelSelection? {
        guard let provider, let entry = catalogue?.first(where: { $0.id == model }) else { return nil }

        return ModelSelection(
            provider: provider,
            model   : entry.id,
            effort  : entry.startingEffort
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let name         = trimmedName
        let role         = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let appearance   = appearance
        let selection    = chosenSelection
        guard !name.isEmpty else { return }

        dismiss()
        Task {
            await team.createWorker(
                name        : name,
                role        : role.isEmpty ? nil : role,
                instructions: instructions.isEmpty ? nil : instructions,
                appearance  : appearance,
                selection   : selection
            )
        }
    }

    /// A random seed and the first palette, both of which the person changes
    /// before saving if they want to.
    private static func startingAppearance() -> WorkerAppearance {
        WorkerAppearance(
            seed            : Int64.random(in: Int64.min...Int64.max),
            generatorVersion: MascotDrawing.generatorVersion,
            palette         : MascotPalette.fallback.name
        )
    }
}

//
//  InspectorModelSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// The worker's profile as it stands: the provider, the model a new turn will
/// use and the provider's connection. The provider row opens in place into
/// the list of providers, one row of the form each, so the form moves the
/// rows below as they come in; its chevron is at the trailing edge and turns
/// with them. Choosing one
/// applies it at once, after asking when the move is between local and cloud
/// or between a subscription and a metered key, and closes the list. The
/// model and the effort are changed from the composer.
struct InspectorModelSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    /// The provider waiting on the person's consent, with the sentence they consent to.
    @State private var pending: (provider: ModelProvider, sentence: String)?

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        Section("Model") {
            providerRow

            if isChoosing {
                ForEach(ModelProvider.allCases) { provider in
                    InspectorProviderRow(
                        provider : provider,
                        isCurrent: provider == worker.configuration?.provider,
                        state    : team.connections.states[provider]
                    ) {
                        choose(provider)
                    }
                    // The first provider stands a little apart from the row that opened the list.
                    .padding(
                        .top,
                        provider == ModelProvider.allCases.first ? 5 : 0
                    )
                    .listRowSeparatorTint(Color(nsColor: .tertiaryLabelColor))
                }
            }

            if let selection = worker.configuration {
                if let refusal = WorkerAnswer(provider: selection.provider).refusal {
                    InspectorDeadEnd(
                        provider: selection.provider,
                        refusal : refusal
                    )
                }

                LabeledContent(
                    "Model",
                    value: selection.line
                )
                LabeledContent("Connection") { connectionState(selection.provider) }
            } else {
                Text("\(worker.name) needs a provider before it can answer.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Change where \(worker.name) runs?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting : pending
        ) { choice in
            Button("Change provider") { apply(choice.provider) }
            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: { choice in
            Text(choice.sentence)
        }
    }

    // MARK: Choosing

    /// The provider, a row that opens and closes the list, its chevron turning with it.
    private var providerRow: some View {
        Button { setChoosing(!isChoosing) } label: {
            LabeledContent("Provider") {
                HStack(spacing: 6) {
                    if let selection = worker.configuration {
                        Text(selection.provider.title)
                    } else {
                        Text("Choose…")
                            .foregroundStyle(.tint)
                    }

                    DisclosureChevron(isOpen: isChoosing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isChoosing ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the providers to choose from")
    }

    /// The list is open while the team says it is for this worker, which the worker's commands also set.
    private var isChoosing: Bool { team.choosingProviderFor == worker.id }

    /// Opens or closes the list in one animation: its rows come in and out, the rows below move,
    /// and the chevron turns.
    private func setChoosing(_ isOpen: Bool) {
        withAnimation(reducesMotion ? nil : .snappy(duration: 0.25)) {
            team.choosingProviderFor = isOpen ? worker.id : nil
        }
    }

    /// Asks first when the move needs consent, and applies it otherwise.
    private func choose(_ provider: ModelProvider) {
        guard provider != worker.configuration?.provider else {
            setChoosing(false)
            return
        }

        let settings = team.connections.providerSettings
        if let previous = worker.configuration?.provider,
           let sentence = ProviderConnection(
               provider: provider,
               settings: settings
           ).consentNeeded(movingFrom: ProviderConnection(
               provider: previous,
               settings: settings
           )) {
            pending = (provider, sentence)
            return
        }
        apply(provider)
    }

    private func apply(_ provider: ModelProvider) {
        setChoosing(false)
        Task {
            await team.changeProvider(
                of: worker.id,
                to: provider
            )
        }
    }

    /// The check of this worker's model when there is one, which also knows a
    /// removed model, else the provider's own.
    @ViewBuilder
    private func connectionState(_ provider: ModelProvider) -> some View {
        if let state = team.modelStates[worker.id] ?? team.connections.states[provider] {
            if state.isReady {
                StatusText(
                    state.title,
                    tone: .ready
                )
            } else {
                VStack(
                    alignment: .trailing,
                    spacing  : 6
                ) {
                    StatusText(
                        state.message,
                        tone: .trouble
                    )
                    Button("Connections…") { team.isShowingConnections = true }
                        .controlSize(.small)
                }
            }
        } else if team.connections.isChecking(provider) {
            StatusText(
                "Checking…",
                tone: .waiting
            )
            .shimmering()
        } else {
            HStack(spacing: 8) {
                StatusText(
                    "Not checked yet",
                    tone: .quiet
                )
                Button {
                    Task { await team.checkModel(of: worker.id) }
                } label: {
                    Label(
                        "Check",
                        systemImage: "arrow.clockwise"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Check")
            }
        }
    }
}

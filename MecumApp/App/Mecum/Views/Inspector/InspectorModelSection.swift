//
//  InspectorModelSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// The worker's profile as it stands: the provider, the model a new turn will
/// use and the provider's connection. The provider row is the way into the
/// profile, a navigation row as System Settings draws one; the model and the
/// effort are changed from the composer.
struct InspectorModelSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    var body: some View {
        Section("Model") {
            Button { team.profileWorkerID = worker.id } label: {
                LabeledContent("Provider") {
                    HStack(spacing: 6) {
                        if let selection = worker.configuration {
                            Text(selection.provider.title)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Choose…")
                                .foregroundStyle(.tint)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change the provider and connection")
            .accessibilityHint("Opens the provider and connection")

            if let selection = worker.configuration {
                LabeledContent(
                    "Model",
                    value: selection.line
                )
                LabeledContent("Connection") { connectionState(selection.provider) }
            } else {
                Text("\(worker.name) needs a model before it can answer.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The check of this worker's model when there is one, which also knows a
    /// removed model, else the provider's own.
    @ViewBuilder
    private func connectionState(_ provider: ModelProvider) -> some View {
        if let state = team.modelStates[worker.id] ?? team.connections.states[provider] {
            StatusText(
                state.isReady ? state.title : state.message,
                tone: state.isReady ? .ready : .trouble
            )
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
                Button("Check") { Task { await team.checkModel(of: worker.id) } }
                    .controlSize(.small)
            }
        }
    }
}

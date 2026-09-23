//
//  WorkerInspectorView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI
import TeamShell
import Workspace

/// WorkerInspectorView is the inspector for the selected worker (§14.2), light
/// for this release: who it is, what it is doing now, its current or last
/// turn, and its provider's connection, with the profile one click away.
///
/// The turn's model and effort are the execution's frozen settings
/// (`TurnSummary`), never the current profile. Memory and the full
/// Capabilities area have no data yet and are left out rather than drawn
/// empty (§21.2). Healthy states are plain text; only a failure carries a mark.
struct WorkerInspectorView: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    private enum TurnReading: Equatable {
        case reading
        case nothingYet
        case read(TurnSummary)
        case failed(String)
    }

    /// What reading the turn again depends on: a new record in the open
    /// conversation, or a turn starting or ending.
    private struct TurnKey: Equatable {
        let workerID : UUID
        let revision : Int
        let isRunning: Bool
    }

    @State private var turn = TurnReading.reading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity
                section("Now") { Text(now) }
                section(turnTitle) { turnContent }
                section("Connection") { connection }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: TurnKey(workerID: worker.id, revision: team.transcriptRevision,
                          isRunning: team.isAnswering(worker.id))) {
            await readTurn()
        }
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: 12) {
            MascotView(appearance: worker.appearance, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(worker.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(role ?? "No role set")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var role: String? {
        let text = worker.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// The row's own activity when there is one. A running turn without the
    /// computer is said here once, and the turn below does not repeat it.
    private var now: String {
        if let activity = team.activity(of: worker.id) { return activity }
        return team.isAnswering(worker.id) ? "Answering" : "Nothing in progress"
    }

    // MARK: Turn

    private var turnTitle: String {
        if case .read(let summary) = turn, summary.state == .running { return "Current turn" }
        return "Last turn"
    }

    @ViewBuilder
    private var turnContent: some View {
        switch turn {
        case .reading:
            ProgressView().controlSize(.small)

        case .nothingYet:
            Text("No turn yet. The model and effort a turn runs with show here once \(worker.name) answers.")
                .foregroundStyle(.secondary)

        case .read(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.modelLine)
                Text(summary.selection.provider.title)
                    .foregroundStyle(.secondary)
                Text("Started \(summary.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                if summary.state != .running {
                    outcome(summary)
                }
            }

        case .failed(let reason):
            trouble("The last turn could not be read. \(reason)")
        }
    }

    @ViewBuilder
    private func outcome(_ summary: TurnSummary) -> some View {
        if case .failed(let reason) = summary.state {
            trouble(reason.isEmpty ? summary.stateTitle : "\(summary.stateTitle): \(reason)")
        } else if summary.isTrouble {
            trouble(summary.stateTitle)
        } else {
            Text(summary.stateTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func readTurn() async {
        do {
            let summary = try await team.latestTurn(of: worker.id)
            turn = summary.map(TurnReading.read) ?? .nothingYet
        } catch {
            turn = .failed(String(describing: error))
        }
    }

    // MARK: Connection

    @ViewBuilder
    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = worker.configuration {
                Text(selection.provider.title)
                connectionState(selection.provider)
                Button("Model and connection…") { team.profileWorkerID = worker.id }
            } else {
                Text("No model attached, so \(worker.name) cannot answer yet.")
                    .foregroundStyle(.secondary)
                Button("Choose a model") { team.profileWorkerID = worker.id }
            }
        }
    }

    /// The check of this worker's model when there is one, which also knows a
    /// removed model, else the provider's own.
    @ViewBuilder
    private func connectionState(_ provider: ModelProvider) -> some View {
        if let state = team.modelStates[worker.id] ?? team.connections.states[provider] {
            if state.isReady {
                Text(state.title)
                    .foregroundStyle(.secondary)
            } else {
                trouble(state.message)
            }
        } else if team.connections.isChecking(provider) {
            Text("Checking…")
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Not checked yet")
                    .foregroundStyle(.secondary)
                Button("Check") { Task { await team.checkModel(of: worker.id) } }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Parts

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// The one mark the inspector uses, a symbol and words, so it does not
    /// depend on colour.
    private func trouble(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .fixedSize(horizontal: false, vertical: true)
    }
}

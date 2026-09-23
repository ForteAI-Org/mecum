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

/// WorkerInspectorView is the inspector for the selected worker (§14.2): what
/// it is doing right now, from the computer it drives to the turn it runs and
/// the connection that turn goes through, with the profile one click away.
///
/// It is a grouped form, the macOS inspector's own shape: one block per part of
/// the flow, label and value in each row, the system's separators between
/// them. The worker's name is small at the top, since the title bar already
/// says it. While the worker has a window open on the computer, its live screen
/// is a block of its own, which can move over the conversation. Colour is kept for state: a dot beside what the worker is doing and
/// how its connection is, and a symbol with every outcome, so nothing depends on
/// colour alone.
///
/// The turn's model and effort are the execution's frozen settings
/// (`TurnSummary`), never the current profile. Memory and the full
/// Capabilities area have no data yet and are left out rather than drawn
/// empty (§21.2).
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
        Form {
            Section { identity }
            Section("Now") { now }
            screen
            Section(turnTitle) { turnRows }
            Section("Connection") { connection }
        }
        .formStyle(.grouped)
        .task(id: TurnKey(workerID: worker.id, revision: team.transcriptRevision,
                          isRunning: team.isAnswering(worker.id))) {
            await readTurn()
        }
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: 10) {
            MascotView(appearance: worker.appearance, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(worker.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(role ?? "No role set")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var role: String? {
        let text = worker.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: Now

    /// Where the worker is in the flow: whether it answers, and what it does with the computer.
    @ViewBuilder
    private var now: some View {
        LabeledContent("Status") {
            if team.isAnswering(worker.id) {
                StatusText("Answering", tone: .active)
            } else {
                StatusText("Idle", tone: .quiet)
            }
        }
        LabeledContent("Computer") { computer }
    }

    @ViewBuilder
    private var computer: some View {
        if team.holdsComputer(worker.id) {
            StatusText(team.activity(of: worker.id) ?? "Using the computer", tone: .active)
        } else if let activity = team.activity(of: worker.id) {
            StatusText(activity, tone: .waiting)
        } else {
            Text("Not in use")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Screen

    /// The live screen while there is a window to watch; nothing otherwise, and
    /// one line while it floats over the conversation.
    @ViewBuilder
    private var screen: some View {
        if team.hasScreen(worker.id) {
            Section("Screen") {
                if team.showsScreenInConversation {
                    LabeledContent("Shown over the conversation") {
                        Button("Put back") { withAnimation(.snappy) { team.showsScreenInConversation = false } }
                            .controlSize(.small)
                    }
                } else {
                    WorkerScreenCard(team: team, worker: worker, place: .inspector)
                }
            }
        }
    }

    // MARK: Turn

    private var turnTitle: String {
        if case .read(let summary) = turn, summary.state == .running { return "Current turn" }
        return "Last turn"
    }

    @ViewBuilder
    private var turnRows: some View {
        switch turn {
        case .reading:
            ProgressView().controlSize(.small)

        case .nothingYet:
            Text("No turn yet. The model and effort a turn runs with show here once \(worker.name) answers.")
                .foregroundStyle(.secondary)

        case .read(let summary):
            LabeledContent("Model", value: summary.modelLine)
            LabeledContent("Provider", value: summary.selection.provider.title)
            LabeledContent("Started") {
                Text(summary.startedAt, format: .relative(presentation: .named))
            }
            .help(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Outcome") { outcome(summary) }

        case .failed(let reason):
            Label("The last turn could not be read. \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    /// The outcome with its own symbol: a running turn in the key colour, a failure in red.
    private func outcome(_ summary: TurnSummary) -> some View {
        let reason: String
        if case .failed(let text) = summary.state, !text.isEmpty { reason = "\(summary.stateTitle): \(text)" }
        else { reason = summary.stateTitle }
        let (symbol, style): (String, AnyShapeStyle) = switch summary.state {
        case .running:    ("circle.dotted", AnyShapeStyle(.tint))
        case .completed:  ("checkmark.circle.fill", AnyShapeStyle(.green))
        case .stopped:    ("stop.circle.fill", AnyShapeStyle(.secondary))
        case .failed:     ("exclamationmark.triangle.fill", AnyShapeStyle(.red))
        case .unfinished: ("exclamationmark.triangle.fill", AnyShapeStyle(.orange))
        }
        return Label {
            Text(reason).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(style)
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
        if let selection = worker.configuration {
            LabeledContent("Provider", value: selection.provider.title)
            LabeledContent("Status") { connectionState(selection.provider) }
            Button("Model and connection…") { team.profileWorkerID = worker.id }
        } else {
            Text("No model attached, so \(worker.name) cannot answer yet.")
                .foregroundStyle(.secondary)
            Button("Choose a model") { team.profileWorkerID = worker.id }
        }
    }

    /// The check of this worker's model when there is one, which also knows a
    /// removed model, else the provider's own.
    @ViewBuilder
    private func connectionState(_ provider: ModelProvider) -> some View {
        if let state = team.modelStates[worker.id] ?? team.connections.states[provider] {
            StatusText(state.isReady ? state.title : state.message, tone: state.isReady ? .ready : .trouble)
        } else if team.connections.isChecking(provider) {
            StatusText("Checking…", tone: .waiting)
        } else {
            HStack(spacing: 8) {
                StatusText("Not checked yet", tone: .quiet)
                Button("Check") { Task { await team.checkModel(of: worker.id) } }
                    .controlSize(.small)
            }
        }
    }
}

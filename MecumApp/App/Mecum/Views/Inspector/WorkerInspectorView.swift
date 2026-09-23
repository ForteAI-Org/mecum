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
/// it is doing right now and the computer it drives, the model and connection
/// its next turn will use, which is the way into its profile, and its current
/// or last turn as it ran.
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
            Section("Model") { model }
            Section(turnTitle) { turnRows }
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
            // Placeholders in the rows' own shape while the turn is read, never a spinning wheel.
            Group {
                LabeledContent("Ran with", value: "a model, an effort")
                LabeledContent("Started", value: "a moment ago")
                LabeledContent("Outcome", value: "Completed")
            }
            .redacted(reason: .placeholder)
            .shimmering()
            .accessibilityLabel("Reading the turn")

        case .nothingYet:
            Text("No turn yet. The model and effort a turn runs with show here once \(worker.name) answers.")
                .foregroundStyle(.secondary)

        case .read(let summary):
            // What the turn ran with, which can differ from the profile above once it changes.
            LabeledContent("Ran with", value: summary.modelLine)
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

    // MARK: Model

    /// The worker's profile as it stands: the model a new turn will use, its
    /// provider and that provider's connection. The model row is the way into
    /// the profile, a navigation row as System Settings draws one.
    @ViewBuilder
    private var model: some View {
        Button { team.profileWorkerID = worker.id } label: {
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    if let selection = worker.configuration {
                        Text(selection.line)
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
        .help("Change the model and connection")
        .accessibilityHint("Opens the model and connection")
        if let selection = worker.configuration {
            LabeledContent("Provider", value: selection.provider.title)
            LabeledContent("Connection") { connectionState(selection.provider) }
        } else {
            Text("\(worker.name) needs a model before it can answer.")
                .foregroundStyle(.secondary)
        }
    }

    /// The check of this worker's model when there is one, which also knows a
    /// removed model, else the provider's own.
    @ViewBuilder
    private func connectionState(_ provider: ModelProvider) -> some View {
        if let state = team.modelStates[worker.id] ?? team.connections.states[provider] {
            StatusText(state.isReady ? state.title : state.message, tone: state.isReady ? .ready : .trouble)
        } else if team.connections.isChecking(provider) {
            StatusText("Checking…", tone: .waiting).shimmering()
        } else {
            HStack(spacing: 8) {
                StatusText("Not checked yet", tone: .quiet)
                Button("Check") { Task { await team.checkModel(of: worker.id) } }
                    .controlSize(.small)
            }
        }
    }
}

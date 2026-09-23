//
//  WorkerConversationView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SwiftUI
import Transcript
import WorkerAgents
import Workspace

/// WorkerConversationView shows one worker's direct conversation.
///
/// The transcript is the AppKit engine of increment 2 (`Transcript`): it loads
/// windows of the history through `TeamModel.transcriptSource`, never the
/// whole of it, refreshes when the model's revision moves, and restores and
/// reports the reading position, anchor and offset, per conversation.
///
/// What is real here is the persistence. The draft reaches the store shortly
/// after typing stops and again when the conversation changes, and sending
/// writes the message first. A worker on Claude Code or Codex then answers
/// through its agent, and its tool use shows as rows apart from its replies;
/// Stop ends the turn.
struct WorkerConversationView: View {

    @Bindable
    var team: TeamModel

    let worker: WorkerSnapshot

    /// Made once for the view and kept while it lives; opening another
    /// conversation reuses it, so the collection view is not rebuilt.
    @State private var transcript: TranscriptController?

    var body: some View {
        VStack(spacing: 0) {
            transcriptArea
            Divider()
            composer
        }
        .navigationTitle(worker.name)
        .navigationSubtitle(team.needsConfiguring(worker) ? TeamRow.toConfigure : "")
    }

    // MARK: Transcript

    private var transcriptArea: some View {
        Group {
            if let transcript {
                TranscriptHost(controller: transcript)
            } else {
                Color.clear
            }
        }
        .task(id: team.conversation?.id) { openTranscript() }
        .onChange(of: team.transcriptRevision) { transcript?.refresh() }
        .overlay {
            if transcript?.isEmpty ?? true {
                ContentUnavailableView(
                    "Nothing said yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("What you write is saved with this worker and is here after a relaunch.")
                )
            }
        }
    }

    /// Opens the conversation at the position it was left at, or at the end.
    private func openTranscript() {
        guard let conversation = team.conversation else { return }
        let controller = transcript ?? TranscriptController(source: team.transcriptSource)
        transcript = controller
        let conversationID = conversation.id
        controller.onReadingPositionChange = { [team] anchor, offset in
            // A report that rests after a switch belongs to the conversation it was read in.
            guard team.conversation?.id == conversationID else { return }
            Task { await team.rememberReadingPosition(anchor, offset: offset) }
        }
        controller.open(
            conversationID,
            workerName   : worker.name,
            appearance   : worker.appearance,
            readingAnchor: conversation.readingAnchorMessageID,
            readingOffset: conversation.readingOffset
        )
    }

    // MARK: Composer

    /// Why this worker cannot answer, when that is known: no model, a model
    /// the catalogue dropped, or a provider this build has no agent for.
    private var modelNotice: String? {
        guard let selection = worker.configuration else {
            return "\(worker.name) has no model attached. What you write is saved and stays here, "
                + "and nothing answers until a model is connected."
        }
        if case .modelRemoved(let model) = team.modelStates[worker.id] {
            return "\(model) is no longer offered by \(selection.provider.title), so \(worker.name) needs "
                + "configuring. Nothing was changed; choose a model to replace it."
        }
        if let refusal = WorkerAnswer(provider: selection.provider).refusal {
            return "\(selection.provider.title) does not answer here yet: \(refusal). What you write is saved, "
                + "and \(worker.name) answers once it uses Claude Code or Codex."
        }
        return nil
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {

            if let notice = modelNotice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Choose a model") { team.profileWorkerID = worker.id }
                        .controlSize(.small)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(worker.name)", text: $team.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .accessibilityLabel("Message \(worker.name)")

                if team.isAnswering(worker.id) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("\(worker.name) is answering")
                    Button("Stop", systemImage: "stop.circle.fill") { team.stopAnswering(worker.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop the answer (Command Period)")
                }

                Button("Send", systemImage: "arrow.up.circle.fill") {
                    Task { await team.send() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(team.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || team.isAnswering(worker.id))
                .help("Send (Command Return)")
            }
        }
        .padding(12)
        // The draft reaches the store once typing pauses. A new keystroke
        // cancels this task and starts it again, so a burst writes once.
        .task(id: team.draft) {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await team.flushDraft()
        }
    }
}

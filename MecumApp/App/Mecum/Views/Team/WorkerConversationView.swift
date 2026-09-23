//
//  WorkerConversationView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SwiftUI
import Workspace

/// WorkerConversationView shows one worker's direct conversation.
///
/// The transcript is a plain SwiftUI list on purpose. Increment 2 replaces it
/// with the AppKit engine that owns long histories, incremental streaming and
/// real anchoring; building any of that now would be work that increment
/// rewrites.
///
/// What is real here is the persistence. The draft reaches the store shortly
/// after typing stops and again when the conversation changes, the reading
/// anchor is written as it moves, and sending writes the message and stops:
/// a model can be attached from the profile, and running the turn with it is
/// the next ticket's, so nothing is routed and nothing answers yet.
struct WorkerConversationView: View {

    @Bindable
    var team: TeamModel

    let worker: WorkerSnapshot

    @State private var position = ScrollPosition()

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .navigationTitle(worker.name)
        .navigationSubtitle(team.needsConfiguring(worker) ? TeamRow.toConfigure : "")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(team.messages) { message in
                    row(message).id(message.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .scrollPosition($position, anchor: .top)
        .onChange(of: position) { _, latest in
            Task { await team.rememberReadingPosition(latest.viewID(type: UUID.self)) }
        }
        .task(id: team.conversation?.id) { restoreReadingPosition() }
        .overlay {
            if team.messages.isEmpty {
                ContentUnavailableView(
                    "Nothing said yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("What you write is saved with this worker and is here after a relaunch.")
                )
            }
        }
    }

    private func row(_ message: MessageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message.isFromPerson ? "You" : worker.name)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(message.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(Self.deliveryText(message.delivery))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The reader goes back where it was, or to the end the first time.
    ///
    /// Plain SwiftUI restores the anchor message and not the offset inside it,
    /// so the store's `readingOffset` is written as zero and stays honest.
    /// Restoring a position within a message needs the AppKit transcript of
    /// increment 2, which measures its own rows.
    private func restoreReadingPosition() {
        guard let anchor = team.conversation?.readingAnchorMessageID else {
            position.scrollTo(edge: .bottom)
            return
        }
        position.scrollTo(id: anchor, anchor: .top)
    }

    private static func deliveryText(_ delivery: MessageDelivery) -> String {
        switch delivery {
        case .savedLocally:  "Saved locally"
        case .pending:       "Waiting"
        case .sentToBackend: "Sent to the model"
        case .responding:    "Answering"
        case .completed:     "Completed"
        case .interrupted:   "Interrupted"
        }
    }

    // MARK: Composer

    /// Why this worker cannot answer, when that is known: no model, a model
    /// the catalogue dropped, or a provider that cannot hold a conversation.
    private var modelNotice: String? {
        guard let selection = worker.configuration else {
            return "\(worker.name) has no model attached. What you write is saved and stays here, "
                + "and nothing answers until a model is connected."
        }
        if case .modelRemoved(let model) = team.modelStates[worker.id] {
            return "\(model) is no longer offered by \(selection.provider.title), so \(worker.name) needs "
                + "configuring. Nothing was changed; choose a model to replace it."
        }
        if let refusal = ProviderConnection(provider: selection.provider).conversationRefusal {
            return "\(selection.provider.title) cannot hold a conversation here: \(refusal). "
                + "\(worker.name) will not answer until it uses another provider."
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

                Button("Send", systemImage: "arrow.up.circle.fill") {
                    Task { await team.send() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(team.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

//
//  WorkerConversationView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI
import Transcript
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

    /// The floating composer's height, which the transcript keeps clear below its last message.
    @State private var composerHeight: CGFloat = 0

    /// The title bar's height, which the transcript scrolls under and keeps clear above its first message.
    @State private var titleBarHeight: CGFloat = 0

    var body: some View {
        transcriptArea
            .overlay(alignment: .top) {
                ConversationTitleBarEdge(titleBarHeight: titleBarHeight)
            }
            .overlay(alignment: .topTrailing) {
                ConversationFloatingScreen(
                    team          : team,
                    worker        : worker,
                    titleBarHeight: titleBarHeight
                )
            }
            .overlay(alignment: .bottom) {
                ConversationComposer(
                    team  : team,
                    worker: worker,
                    height: $composerHeight
                )
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { titleBarHeight = $0 }
    }

    // MARK: Transcript

    private var transcriptArea: some View {
        Group {
            if let transcript {
                TranscriptHost(
                    controller : transcript,
                    topInset   : titleBarHeight + 8,
                    bottomInset: composerHeight
                )
                // Under the title bar, so messages scroll beneath the worker's name as the system draws it.
                .ignoresSafeArea(
                    .container,
                    edges: .top
                )
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

            Task {
                await team.rememberReadingPosition(
                    anchor,
                    offset: offset
                )
            }
        }
        controller.open(
            conversationID,
            workerName   : worker.name,
            appearance   : worker.appearance,
            readingAnchor: conversation.readingAnchorMessageID,
            readingOffset: conversation.readingOffset
        )
    }
}

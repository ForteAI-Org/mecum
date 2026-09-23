//
//  WorkerConversationView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Composer
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

    /// The floating composer's height, which the transcript keeps clear below its last message.
    @State private var composerHeight: CGFloat = 0

    /// The title bar's height, which the transcript scrolls under and keeps clear above its first message.
    @State private var titleBarHeight: CGFloat = 0

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// True for the instant a newly drawn conversation starts its entrance.
    @State private var isArriving = false

    var body: some View {
        transcriptArea
            .overlay(alignment: .top) { titleBarEdge }
            .overlay(alignment: .topTrailing) { floatingScreen }
            .overlay(alignment: .bottom) { composer }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { titleBarHeight = $0 }
    }

    /// The worker's live screen at the top right, below the title bar, when the
    /// person moved it here from the inspector and there is a window to watch.
    @ViewBuilder
    private var floatingScreen: some View {
        if team.showsScreenInConversation, team.hasScreen(worker.id) {
            WorkerScreenCard(team: team, worker: worker, place: .conversation)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .frame(width: 280)
                .padding(.top, titleBarHeight + 8)
                .padding(.trailing, 16)
                .ignoresSafeArea(.container, edges: .top)
                .transition(.scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
        }
    }

    /// The soft edge the messages fade under at the title bar, as a system scroll
    /// view gets on its own: the system gives that edge only to SwiftUI's scroll
    /// views, and the transcript is an AppKit one. It is the bar's material,
    /// solid under the bar and fading out just below it, and it takes no clicks.
    private var titleBarEdge: some View {
        Rectangle()
            .fill(.bar)
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.6),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(height: titleBarHeight + 20)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Transcript

    private var transcriptArea: some View {
        Group {
            if let transcript {
                TranscriptHost(controller: transcript, topInset: titleBarHeight + 8, bottomInset: composerHeight)
                    // Under the title bar, so messages scroll beneath the worker's name as the system draws it.
                    .ignoresSafeArea(.container, edges: .top)
                    // The old conversation stays until the new one is drawn, which then comes in:
                    // nothing is ever blank while it loads.
                    .opacity(isArriving ? 0.3 : 1)
                    .offset(y: isArriving && !reducesMotion ? 10 : 0)
                    .onChange(of: transcript.shownConversationID) { arrive() }
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

    /// Starts a newly drawn conversation a little faded and low, then lets it settle into place.
    private func arrive() {
        var start = Transaction()
        start.disablesAnimations = true
        withTransaction(start) { isArriving = true }
        withAnimation(reducesMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28)) { isArriving = false }
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

    /// Whether this worker can answer: it has a model the catalogue still
    /// offers, on a provider this build has an agent for. The inspector shows
    /// which of these is missing; the composer only says to choose a model.
    private var canAnswer: Bool {
        guard let selection = worker.configuration else { return false }
        if case .modelRemoved = team.modelStates[worker.id] { return false }
        return WorkerAnswer(provider: selection.provider).refusal == nil
    }

    /// The composer (§13), floating over the transcript's bottom edge. Its field
    /// hands the draft committed text only, never a composition in progress, so
    /// the pause below writes finished text.
    private var composer: some View {
        ComposerBar(
            draft      : $team.draft,
            recipient  : worker.name,
            canAnswer  : canAnswer,
            isAnswering: team.isAnswering(worker.id),
            send       : { Task { await team.send() } },
            stop       : { team.stopAnswering(worker.id) },
            release    : team.holdsComputer(worker.id) ? { Task { await team.releaseComputer(worker.id) } } : nil
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        // The draft reaches the store once typing pauses. A new keystroke
        // cancels this task and starts it again, so a burst writes once.
        .task(id: team.draft) {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await team.flushDraft()
        }
    }
}

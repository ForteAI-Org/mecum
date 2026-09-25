//
//  ConversationComposer.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SwiftUI

/// The composer (§13), floating over the transcript's bottom edge. Its field
/// hands the draft committed text only, never a composition in progress, so
/// the pause below writes finished text.
struct ConversationComposer: View {

    @Bindable
    var team: TeamModel

    let worker: WorkerSnapshot

    /// The composer's height, which the transcript keeps clear below its last message.
    @Binding var height: CGFloat

    /// The model and effort chosen in the popup and not kept yet, nil while they are the worker's.
    @State private var pending: ModelSelection?

    @State private var isChoosingModel = WindowSnapshots.opensModelPopup

    @AppStorage(AppPreferences.chatSendsWithCommandReturn)
    private var sendsWithCommandReturn = AppPreferences.chatSendsWithCommandReturnDefault

    /// The model button's frame in the window, which the popup is centred on.
    @State private var modelButton = CGRect.zero

    @State private var isShowingContext = WindowSnapshots.opensContextPopup

    /// The context ring's frame in the window, which its popup is placed over.
    @State private var contextButton = CGRect.zero

    var body: some View {
        // The ring sits above the bar's trailing edge, inside the height the transcript keeps clear.
        VStack(
            alignment: .trailing,
            spacing  : 6
        ) {
            if let context {
                ConversationContextButton(
                    context: context,
                    isOpen : $isShowingContext,
                    frame  : $contextButton
                )
                .padding(
                    .trailing,
                    16
                )
            }

            bar
        }
        .composerPopup(
            isPresented: $isShowingContext,
            button     : contextButton,
            width      : ConversationContextPopup.width
        ) {
            if let context { ConversationContextPopup(context: context) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: worker.id) {
            isChoosingModel  = false
            isShowingContext = false
            pending          = nil
        }
        .onChange(of: context == nil) {
            if context == nil { isShowingContext = false }
        }
        // The draft reaches the store once typing pauses. A new keystroke
        // cancels this task and starts it again, so a burst writes once.
        .task(id: team.draft) {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await team.flushDraft()
        }
    }

    /// The selected worker's context while its conversation is open, nil while its fill or window is unknown.
    private var context: WorkerUsage.Context? {
        team.conversation == nil ? nil : UsageWording.ringContext(of: team.usage[worker.id])
    }

    private var bar: some View {
        ComposerBar(
            draft      : $team.draft,
            recipient  : worker.name,
            canAnswer  : canAnswer,
            isAnswering: team.isAnswering(worker.id),
            send       : { Task { await keepChoice(); await team.send() } },
            stop       : { team.stopAnswering(worker.id) },
            release    : team.holdsComputer(worker.id) ? { Task { await team.releaseComputer(worker.id) } } : nil
        )
        .sendsOnReturn(!sendsWithCommandReturn)
        .accessory {
            if let configuration = worker.configuration {
                ConversationModelButton(
                    selection: pending ?? configuration,
                    catalogue: team.connections.catalogues[configuration.provider],
                    isOpen   : $isChoosingModel,
                    frame    : $modelButton,
                    isEnabled: !team.isAnswering(worker.id)
                )
            }
        }
        .modelPopup(
            isPresented: $isChoosingModel,
            button     : modelButton,
            selection  : Binding(
                get: { pending ?? worker.configuration ?? .default },
                set: { pending = $0 }
            ),
            catalogue  : worker.configuration.flatMap { team.connections.catalogues[$0.provider] },
            onClose    : { Task { await keepChoice() } }
        )
    }

    /// Makes the popup's choice the worker's, a new version of its profile, when it changed anything.
    private func keepChoice() async {
        guard let choice = pending else { return }

        pending = nil
        guard choice != worker.configuration else { return }

        await team.configure(
            worker.id,
            selection: choice
        )
    }

    /// Whether this worker can answer: it has a model the catalogue still
    /// offers. The inspector shows which of these is missing; the composer
    /// only says to choose a model.
    private var canAnswer: Bool {
        guard worker.configuration != nil else { return false }
        if case .modelRemoved = team.modelStates[worker.id] { return false }

        return true
    }
}

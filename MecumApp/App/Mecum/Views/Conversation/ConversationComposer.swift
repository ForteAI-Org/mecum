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

    var body: some View {
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: worker.id) {
            isChoosingModel = false
            pending         = nil
        }
        // The draft reaches the store once typing pauses. A new keystroke
        // cancels this task and starts it again, so a burst writes once.
        .task(id: team.draft) {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await team.flushDraft()
        }
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
    /// offers, on a provider that answers in this build (`WorkerAnswer`). The
    /// inspector shows which of these is missing; the composer only says to
    /// choose a model.
    private var canAnswer: Bool {
        guard let selection = worker.configuration else { return false }
        if case .modelRemoved = team.modelStates[worker.id] { return false }

        return WorkerAnswer(provider: selection.provider).refusal == nil
    }
}

//
//  TeamModel+SlashCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import Foundation
import ModelTransports

/// The composer's commands (`SlashCommand`), run here with the actions the
/// conversation's controls already use. A command never becomes a message,
/// never reaches an agent and never joins the queue.
extension TeamModel {

    /// The open conversation's worker as the commands read it, nil while no
    /// worker's conversation is open. The counter and the ring are shown as
    /// the toolbar and the composer show them.
    var slashCommandContext: SlashCommandContext? {
        guard let id = conversation?.participantIDs.first, let worker = worker(id) else { return nil }

        let selection = worker.configuration
        return SlashCommandContext(
            worker                   : worker.name,
            isAnswering              : isAnswering(id),
            isCompacting             : isCompacting(id),
            holdsComputer            : holdsComputer(id),
            hasScreen                : hasScreen(id),
            showsScreenInConversation: showsScreenInConversation,
            showsCounter             : UsageWording.counter(of: usage[id]) != nil,
            showsRing                : UsageWording.ringContext(of: usage[id]) != nil,
            selection                : selection,
            catalogue                : selection.flatMap { connections.catalogues[$0.provider] }
        )
    }

    /// Runs `invocation` when it can run now: the draft empties and is saved
    /// as a sent draft is, its quote stays for the next message, and the
    /// command's action follows. One that cannot run does nothing, and the
    /// draft stays as typed.
    func run(_ invocation: SlashCommandInvocation) async {
        guard let id = conversation?.participantIDs.first, let action = slashCommandContext?.action(for: invocation)
        else { return }

        draft = ""
        switch action {
        case .compact:
            compactContext(of: id)

        case .startFresh:
            await startFreshContext(of: id)

        case .chooseModel:
            modelPopupRequest += 1

        case .select(let selection):
            if selection != worker(id)?.configuration {
                await configure(
                    id,
                    selection: selection
                )
            }

        case .stop:
            stopAnswering(id)

        case .release:
            await releaseComputer(id)

        case .showScreen(let inConversation):
            showsScreenInConversation = inConversation

        case .showUsage:
            showsUsage = true

        case .showContext:
            showsContext = true

        case .observe:
            await observeScreen(of: id)
        }
        await flushDraft()
    }
}

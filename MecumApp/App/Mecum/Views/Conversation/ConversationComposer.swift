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
///
/// A reply in progress shows as a strip joined to the pill's top, with the
/// quoted message: a click on its text goes to that message, and its × or
/// Escape in the field drops the quote. The next send carries it.
///
/// A message sent while the worker answers joins the conversation's queue,
/// which shows as a strip above the reply's (`ConversationQueueStrip`): the
/// reply strip stays next to the pill, since it belongs to what is typed.
///
/// A draft that starts with `/` opens the command popup above the pill, at its
/// leading edge (`SlashCommandPopup`). The keyboard stays in the field, which
/// hands the popup ↑ ↓, Tab, Return and Escape while it is open; a first
/// Escape closes it, and the next one drops a quote as it always does.
struct ConversationComposer: View {

    @Bindable
    var team: TeamModel

    let worker: WorkerSnapshot

    /// The composer's height, strip included, which the transcript keeps clear below its last message.
    @Binding var height: CGFloat

    /// A count that puts the keyboard in the field each time it moves.
    var focusRequest = 0

    /// Moves when a queued message comes back into the draft, to be edited at once.
    @State private var editFocus = 0

    /// Shows a message in the transcript, as a click on the reply strip asks.
    var reveal: (UUID) -> Void = { _ in }

    /// The model and effort chosen in the popup and not kept yet, nil while they are the worker's.
    @State private var pending: ModelSelection?

    @State private var isChoosingModel = WindowSnapshots.opensModelPopup

    @AppStorage(AppPreferences.chatSendsWithCommandReturn)
    private var sendsWithCommandReturn = AppPreferences.chatSendsWithCommandReturnDefault

    /// The model button's frame in the window, which the popup is centred on.
    @State private var modelButton = CGRect.zero

    /// The command popup's selection, and the draft it was closed on.
    @State private var commands = SlashCommandMenu()

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

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
        .queuesWhileAnswering(true)
        .onEscape(team.draftQuote == nil ? nil : { team.draftQuote = nil })
        .popupKeys { key in
            commands.handle(
                key,
                in: team
            )
        }
        .focusRequest(focusRequest + editFocus)
        .strip {
            VStack(spacing: 0) {
                if !team.queue.isEmpty {
                    queueStrip
                        .transition(ComposerBar.stripTransition(reducesMotion: reducesMotion))
                }
                if let quote = team.draftQuote {
                    replyStrip(quote)
                        .transition(ComposerBar.stripTransition(reducesMotion: reducesMotion))
                }
            }
        }
        .leading {
            if let context {
                ConversationContextButton(
                    context        : context,
                    lastTurn       : team.usage[worker.id]?.lastTurn?.turn,
                    worker         : worker.name,
                    isCompacting   : team.isCompacting(worker.id),
                    waitReason     : team.isAnswering(worker.id)
                        ? UsageWording.actionsWait(
                            worker      : worker.name,
                            isCompacting: team.isCompacting(worker.id)
                        )
                        : nil,
                    compact        : { team.compactContext(of: worker.id) },
                    startFresh     : { Task { await team.startFreshContext(of: worker.id) } },
                    isShowingDetail: $team.showsContext
                )
                .padding(
                    .trailing,
                    8
                )
                // It comes out of the pill's leading edge and goes back into it, as Release does from Send.
                .transition(
                    .scale(
                        scale : 0.3,
                        anchor: .trailing
                    )
                    .combined(with: .opacity)
                )
            }
        }
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
        .composerPopup(
            isPresented   : Binding(
                get: { !commands.rows(of: team).isEmpty },
                set: { if !$0 { commands.close(on: team.draft) } }
            ),
            placement     : .leading,
            width         : SlashCommandPopup.width,
            closesOnEscape: false
        ) {
            let rows = commands.rows(of: team)
            SlashCommandPopup(
                rows    : rows,
                selected: commands.selected(in: rows)?.id,
                select  : { row in
                    commands.select(
                        row,
                        in: rows
                    )
                },
                choose  : { row in
                    commands.choose(
                        row,
                        in: team
                    )
                }
            )
        }
        .animation(reducesMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: context == nil)
        .animation(
            ComposerBar.stripAnimation,
            value: team.draftQuote
        )
        .animation(
            ComposerBar.stripAnimation,
            value: team.queue
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: worker.id) {
            isChoosingModel = false
            pending         = nil
        }
        // `/model` alone opens the popup, as the model button does.
        .onChange(of: team.modelPopupRequest) { isChoosingModel = true }
        // The model popup takes the command popup's place; a new draft opens the command popup again.
        .onChange(of: isChoosingModel) {
            if isChoosingModel { commands.close(on: team.draft) }
        }
        .onChange(of: team.draft) { commands.draftChanged(to: team.draft) }
        // The draft reaches the store once typing pauses. A new keystroke
        // cancels this task and starts it again, so a burst writes once.
        .task(id: team.draft) {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await team.flushDraft()
        }
        // A quote comes and goes in one act, not in keystrokes, so it is written at once.
        .task(id: team.draftQuote) { await team.flushDraft() }
    }

    /// The strip of a reply in progress: the reply symbol, the worker's name when
    /// the quote is theirs, the quoted words on one line, and × to drop the quote.
    /// A quote of the person's own message has no name; the symbol takes the
    /// accent instead, as the bar of such a quote does in a bubble.
    private func replyStrip(_ quote: MessageQuote) -> some View {
        let author = quote.isFromPerson ? nil : worker.name
        return ComposerStrip(
            symbol           : "arrowshape.turn.up.left",
            tint             : quote.isFromPerson ? .accentColor : .secondary,
            title            : author,
            text             : quote.excerpt,
            accessibilityText: "Replying to \(author ?? "your message"): \(quote.excerpt)",
            roundsTop        : team.queue.isEmpty,
            open             : { reveal(quote.messageID) }
        ) {
            ComposerStripCancelButton(
                help  : "Don’t reply to this message.",
                label : "Cancel Reply",
                action: { team.draftQuote = nil }
            )
        }
        .help("Show the message you’re replying to.")
    }

    /// The conversation's queue, showing the message that goes next.
    private var queueStrip: some View {
        ConversationQueueStrip(
            queue      : team.queue,
            shown      : team.shownQueuedIndex,
            isAnswering: team.isAnswering(worker.id),
            next       : { team.showNextQueued() },
            sendNow    : { Task { await team.sendQueuedNow() } },
            edit       : {
                editFocus += 1
                Task { await team.editShownQueued() }
            },
            remove     : { Task { await team.removeShownQueued() } }
        )
    }

    /// The selected worker's context while its conversation is open, nil while its fill or window is unknown.
    private var context: WorkerUsage.Context? {
        team.conversation == nil ? nil : UsageWording.ringContext(of: team.usage[worker.id])
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

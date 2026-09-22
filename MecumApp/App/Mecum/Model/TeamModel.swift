//
//  TeamModel.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Observation
import Workspace

/// TeamModel is the only thing in the app that talks to `WorkspaceStore`.
///
/// The store is an actor holding a SwiftData context; every call here awaits
/// it and keeps the snapshots it hands back. Views read this object and never
/// the store, so no view holds a model row and no row crosses an isolation
/// boundary.
///
/// It touches `SeatBroker` nowhere. A worker in the team acquires no seat: a
/// conversation and a draft are text in a database, and the desktop is a
/// later increment's capability.
///
/// A refusal from the store becomes `problem`, a sentence naming what was
/// refused and what to do about it. Nothing here fails silently.
@Observable
@MainActor
final class TeamModel {

    private let store: WorkspaceStore

    /// The active team and the archive, as the store last answered.
    private(set) var active  : [WorkerSnapshot] = []
    private(set) var archived: [WorkerSnapshot] = []

    /// Managers whose reports are folded away. It is view state, not stored
    /// state: increment 2 remembers the open branches per window.
    var collapsed: Set<UUID> = []

    var selection       : UUID?
    var isCreatingWorker = false

    /// What the store refused, in a sentence. Nil while nothing is pending.
    var problem: String?

    private(set) var conversation: ConversationSnapshot?
    private(set) var messages    : [MessageSnapshot] = []

    /// The draft as typed. It reaches the store on a pause and when the
    /// conversation changes, not on every keystroke; `savedDraft` is what the
    /// store holds, so an unchanged draft writes nothing.
    var draft: String = ""

    private var savedDraft: String = ""

    init(store: WorkspaceStore) {
        self.store = store
    }

    // MARK: Reading

    /// The sidebar's rows, recomputed from the team and the folded managers.
    /// The team is tens of workers, so this is cheaper than keeping a second
    /// copy in step with two sources.
    var rows: [TeamRow] { TeamOutline.rows(of: active, collapsed: collapsed) }

    var selectedWorker: WorkerSnapshot? { selection.flatMap(worker) }

    func worker(_ id: UUID) -> WorkerSnapshot? {
        active.first { $0.id == id } ?? archived.first { $0.id == id }
    }

    /// Every other active worker. Which of them would close a loop is the
    /// store's answer, not this list's: offering only the safe ones would be
    /// a second copy of an invariant that already has an owner.
    func candidateManagers(for id: UUID) -> [WorkerSnapshot] {
        active.filter { $0.id != id }
    }

    func load() async {
        do {
            let everyone = try await store.workers(includingArchived: true)
            active   = everyone.filter { !$0.isArchived }
            archived = everyone.filter(\.isArchived)
        } catch {
            problem = "The team could not be read, so the list below may be out of date. \(describe(error))"
        }
    }

    // MARK: The conversation

    /// Opens the selected worker's direct conversation, creating it the first
    /// time. The outgoing draft is written first, so switching worker while
    /// something is typed does not lose it.
    func openSelectedConversation() async {
        await flushDraft()
        conversation = nil
        messages     = []
        draft        = ""
        savedDraft   = ""

        guard let id = selection else { return }
        do {
            // One direct conversation per worker, found by its participant, in
            // a linear scan over the handful a person has in increment 1.
            let existing = try await store.conversations().first {
                $0.kind == .direct && $0.participantIDs == [id]
            }
            let opened: ConversationSnapshot
            if let existing {
                opened = existing
            } else {
                opened = try await store.createConversation(kind: .direct, participants: [id])
            }
            conversation = opened
            draft        = opened.draft
            savedDraft   = opened.draft
            messages     = try await store.messages(in: opened.id)
        } catch {
            problem = "This worker's conversation could not be opened. \(describe(error))"
        }
    }

    /// Writes the draft if it differs from what the store holds.
    func flushDraft() async {
        guard let conversation, draft != savedDraft else { return }
        do {
            self.conversation = try await store.update(conversation: conversation.id, .draft(draft))
            savedDraft        = draft
        } catch {
            problem = "The draft could not be saved, so it may not survive quitting. \(describe(error))"
        }
    }

    /// Persists the message and stops. No model is attached to any worker in
    /// this increment, so nothing is routed and nothing answers; the message
    /// stays at the delivery state the store writes it with.
    func send() async {
        guard let conversation else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            messages.append(try await store.appendMessage(to: conversation.id, text: text))
            draft      = ""
            savedDraft = ""
            self.conversation = try await store.update(conversation: conversation.id, .draft(""))
        } catch {
            problem = "The message was not saved, so it was not sent either. \(describe(error))"
        }
    }

    /// Remembers which message the reader is anchored on.
    func rememberReadingPosition(_ anchor: UUID?) async {
        guard let conversation, conversation.readingAnchorMessageID != anchor else { return }
        do {
            self.conversation = try await store.update(
                conversation: conversation.id,
                .readingPosition(anchorMessageID: anchor, offset: 0)
            )
        } catch {
            problem = "The reading position could not be remembered. \(describe(error))"
        }
    }

    // MARK: Writing the team

    /// Creates a worker with no model attached, which is the only kind this
    /// increment makes. Creation is always the person's act: nothing else in
    /// the app calls this.
    func createWorker(
        name        : String,
        role        : String?,
        instructions: String?,
        appearance  : WorkerAppearance
    ) async {
        do {
            let made = try await store.createWorker(
                name        : name,
                role        : role,
                instructions: instructions,
                appearance  : appearance
            )
            await load()
            selection = made.id
            await openSelectedConversation()
        } catch {
            problem = "The worker was not created. \(describe(error))"
        }
    }

    func changeManager(of id: UUID, to manager: UUID?) async {
        do {
            try await store.update(worker: id, .manager(manager))
            await load()
        } catch {
            problem = describe(error)
        }
    }

    /// Archiving is the ordinary removal from the active team. The worker,
    /// its conversation and its attributions stay readable in the archive.
    func setArchived(_ isArchived: Bool, for id: UUID) async {
        do {
            try await store.update(worker: id, .archived(isArchived))
            if isArchived, selection == id {
                selection = nil
                await openSelectedConversation()
            }
            await load()
        } catch {
            problem = isArchived
                ? "The worker was not archived and is still on the active team. \(describe(error))"
                : "The worker was not restored and is still in the archive. \(describe(error))"
        }
    }

    // MARK: Refusals

    /// Turns a refusal into a sentence with the fact, the impact and the next
    /// action, rather than a type name the person cannot act on.
    private func describe(_ error: any Error) -> String {
        guard let refusal = error as? WorkspaceStoreError else { return String(describing: error) }

        switch refusal {
        case .cycleInHierarchy(let workerID, let managerID):
            return """
            \(name(of: workerID)) cannot report to \(name(of: managerID)), because that \
            manager already reports to it, directly or through someone else. Nothing was \
            changed. Choose a manager from outside its own reports, or move that manager first.
            """

        case .workerNotFound:
            return "That worker is no longer in the workspace. Nothing was changed; reopen the team."

        case .conversationNotFound:
            return "That conversation is no longer in the workspace. Select the worker again to open a new one."

        case .messageNotFound:
            return "That message is no longer in the workspace. Nothing was changed."

        case .workerNotConfigured(let id):
            return "\(name(of: id)) has no model attached, so nothing can run for it. Connect a model first."

        case .openFailed(let underlying):
            return "The workspace database did not open, so nothing was saved. \(underlying)"

        case .migrationFailed(let underlying, let restoreFailure):
            let restore = restoreFailure.map { " The previous version could not be put back: \($0)" } ?? ""
            return "The workspace database did not upgrade, so nothing was saved. \(underlying)\(restore)"
        }
    }

    private func name(of id: UUID) -> String {
        worker(id)?.name ?? "That worker"
    }
}

//
//  SlashCommandMenu.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import Foundation
import Observation

/// SlashCommandMenu is the composer's command popup as state: the row moved
/// to with ↑ ↓ or the pointer, and the draft Escape or a click outside closed
/// the popup on. What the popup lists is read from the team each time, so a
/// key pressed before SwiftUI has drawn the last keystroke acts on the draft
/// as typed. A command runs through `TeamModel.send`, which checks once more
/// that it can run, as it does for a command typed out and sent.
@MainActor
@Observable
final class SlashCommandMenu {

    /// The row moved to, and the rows it was moved among: rows that change start over on
    /// their first available row.
    private var selection: SlashCommandSuggestions.Row.ID?
    private var moved    : [SlashCommandSuggestions.Row.ID] = []

    /// The draft the popup was closed on. It stays closed until the draft changes.
    private var closedDraft: String?

    /// What the popup lists for `team`'s draft now, none while it is closed.
    func rows(of team: TeamModel) -> [SlashCommandSuggestions.Row] {
        guard team.draft != closedDraft, let context = team.slashCommandContext else { return [] }

        return SlashCommandSuggestions(
            draft  : team.draft,
            context: context
        ).rows
    }

    /// The row the popup marks, which Tab and Return act on: the one moved to while the rows
    /// stayed the same, else the first that can run, else the first.
    func selected(in rows: [SlashCommandSuggestions.Row]) -> SlashCommandSuggestions.Row? {
        if rows.map(\.id) == moved, let row = rows.first(where: { $0.id == selection }) { return row }
        return rows.first { $0.unavailableReason == nil } ?? rows.first
    }

    func select(
        _ row  : SlashCommandSuggestions.Row,
        in rows: [SlashCommandSuggestions.Row]
    ) {
        selection = row.id
        moved     = rows.map(\.id)
    }

    /// Closes the popup until the draft is no longer `draft`.
    func close(on draft: String) {
        closedDraft = draft
    }

    /// Forgets a close once the draft has changed, so typing opens the popup again.
    func draftChanged(to draft: String) {
        if draft != closedDraft { closedDraft = nil }
    }

    /// Answers a key the composer's field offers, and whether the popup took it:
    /// while it is closed it takes none, and the key goes on as it always did.
    func handle(
        _ key  : ComposerTextView.PopupKey,
        in team: TeamModel
    ) -> Bool {
        let rows = rows(of: team)
        guard let row = selected(in: rows), let index = rows.firstIndex(of: row) else { return false }

        switch key {
        case .up, .down:
            let step = key == .up ? rows.count - 1 : 1
            select(
                rows[(index + step) % rows.count],
                in: rows
            )

        case .complete:
            team.draft = row.completion

        case .run:
            choose(
                row,
                in: team
            )

        case .close:
            close(on: team.draft)
        }
        return true
    }

    /// What Return or a click does with `row`: runs it, puts it in the draft
    /// when it needs more, or nothing while it cannot run, and the draft stays.
    func choose(
        _ row  : SlashCommandSuggestions.Row,
        in team: TeamModel
    ) {
        guard row.unavailableReason == nil else { return }

        team.draft = row.completion
        guard row.runsOnReturn else { return }

        Task { await team.send() }
    }
}

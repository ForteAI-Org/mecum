//
//  TeamMenuCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// TeamMenuCommands is the menu bar's Team menu: the connections, and what can
/// be done to the selected worker, for the key team window.
///
/// The toolbar no longer holds either (§3.4), so this is where the keyboard
/// reaches them: the sidebar's footer and a row's context menu are the same
/// commands for the pointer. With no team window in front the menu is disabled.
struct TeamMenuCommands: Commands {

    @FocusedValue(\.team)
    private var team

    var body: some Commands {
        CommandMenu("Team") {
            Button("Connections…") { team?.isShowingConnections = true }
                .disabled(team == nil)

            Divider()

            if let team, let worker = team.selectedWorker {
                WorkerCommands(
                    worker: worker,
                    team  : team
                )
            } else {
                Button("No worker selected") {}
                    .disabled(true)
            }
        }
    }
}

extension FocusedValues {

    /// The key team window's team, published by `TeamShellView`.
    @Entry var team: TeamModel?
}

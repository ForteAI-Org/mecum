//
//  TeamWindowView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SeatBroker
import SwiftUI

/// TeamWindowView is the app's front door: it opens the workspace and hands
/// the team to `TeamShellView`, the three areas of the window.
///
/// It is also the window's memory (§3.1). Whether the inspector was asked
/// for and the selected worker are scene storage, so each window restores its
/// own; the column widths are the split view's, restored with the window, and
/// a new window starts from the tokens.
///
/// A store that did not open says so. It does not show an empty team, which
/// would read as "you have no workers" when the truth is "nothing could be
/// read".
struct TeamWindowView: View {

    var launch: WorkspaceLaunch

    /// The connections the team's workers use, shared with the Settings window.
    var connections: ModelSettingsStore

    /// The broker the workers' desktop goes through, the app's one.
    var broker: SeatBroker

    /// Told once the team is made, so quitting can write what is typed in it.
    var didOpenTeam: (TeamModel) -> Void

    @State private var team: TeamModel?

    /// Closed in a new window, and as the person left it in a restored one.
    @SceneStorage("team.inspectorRequested")
    private var isInspectorRequested = false

    /// The selected worker's id, empty for none.
    @SceneStorage("team.selection")
    private var storedSelection = ""

    var body: some View {
        content
            .frame(
                minWidth : ShellMetrics.windowMinimum,
                minHeight: 560
            )
            .task {
                launch.open()
                guard team == nil, let store = launch.store else { return }

                let model = TeamModel(
                    store      : store,
                    connections: connections,
                    broker     : broker
                )
                didOpenTeam(model)
                await model.load()
                restore(into: model)
                team = model
                await model.openSelectedConversation()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let team {
            
            TeamShellView(
                team                : team,
                isInspectorRequested: $isInspectorRequested
            )
            .onChange(of: team.selection) {
                storedSelection = team.selection?.uuidString ?? ""
            }
            
        } else if let failure = launch.failure {
            
            ContentUnavailableView {
                Label(
                    "Couldn’t Open the Workspace",
                    systemImage: "externaldrive.badge.xmark"
                )
                
            } description: {
                Text("Mecum couldn’t load your team or conversations.\n\nDetails: \(failure)")
            }
            
        } else {
            Text("Opening workspace…")
                .foregroundStyle(.secondary)
                .shimmering()
        }
    }

    /// Puts back this window's selection. A worker that
    /// is no longer in the workspace is dropped rather than selected.
    private func restore(into team: TeamModel) {
        if let id = UUID(uuidString: storedSelection), team.worker(id) != nil {
            team.selection = id
        }
    }
}

//
//  TeamWindowView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SeatBroker
import SwiftUI
import Workspace

/// TeamWindowView is the app's front door: the team on the left, the selected
/// worker's conversation on the right.
///
/// Two columns and no inspector. The hideable inspector, the three-panel shell
/// and the AppKit transcript are increment 2; what this window has to prove is
/// that workers and their drafts are still here after a relaunch.
///
/// A store that did not open says so. It does not show an empty team, which
/// would read as "you have no workers" when the truth is "nothing could be
/// read".
struct TeamWindowView: View {

    var launch: WorkspaceLaunch

    /// The connections the team's workers use, shared with the lab's Settings.
    var connections: ModelSettingsStore

    /// The broker the workers' desktop goes through, shared with the lab.
    var broker: SeatBroker

    /// Told once the team is made, so quitting can write what is typed in it.
    var didOpenTeam: (TeamModel) -> Void

    @State private var team: TeamModel?

    var body: some View {
        content
            .frame(minWidth: 840, minHeight: 560)
            .task {
                launch.open()
                guard team == nil, let store = launch.store else { return }
                let model = TeamModel(store: store, connections: connections, broker: broker)
                didOpenTeam(model)
                await model.load()
                team = model
            }
    }

    @ViewBuilder
    private var content: some View {
        if let team {
            split(team)
        } else if let failure = launch.failure {
            ContentUnavailableView {
                Label("The workspace did not open", systemImage: "externaldrive.badge.xmark")
            } description: {
                Text(
                    """
                    The team and its conversations live in a database that could not be opened, \
                    so nothing is listed rather than an empty team. \(failure)
                    """
                )
            }
        } else {
            ProgressView()
        }
    }

    private func split(_ team: TeamModel) -> some View {
        NavigationSplitView {
            TeamSidebarView(team: team)
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            detail(team)
        }
        .onChange(of: team.selection) {
            Task { await team.openSelectedConversation() }
        }
        .sheet(isPresented: Bindable(team).isCreatingWorker) {
            NewWorkerSheet(team: team)
        }
        .sheet(isPresented: Bindable(team).isShowingConnections) {
            ConnectionsSheet(connections: team.connections)
        }
        .sheet(item: profileWorker(team)) { worker in
            WorkerProfileSheet(team: team, worker: worker)
        }
        .toolbar {
            ToolbarItem {
                Button("Connections", systemImage: "point.3.connected.trianglepath.dotted") {
                    team.isShowingConnections = true
                }
                .help("The model connections the team uses")
            }
        }
        .alert(
            "That could not be done",
            isPresented: Binding(
                get: { team.problem != nil },
                set: { if !$0 { team.problem = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(team.problem ?? "")
        }
    }

    @ViewBuilder
    private func detail(_ team: TeamModel) -> some View {
        if let worker = team.selectedWorker {
            WorkerConversationView(team: team, worker: worker)
        } else if team.active.isEmpty && team.archived.isEmpty {
            firstLaunch(team)
        } else {
            ContentUnavailableView(
                "No worker selected",
                systemImage: "person.crop.circle",
                description: Text("Choose a worker in the team to open its conversation.")
            )
        }
    }

    /// The worker being edited, as the sheet's item. Closing the sheet clears it.
    private func profileWorker(_ team: TeamModel) -> Binding<WorkerSnapshot?> {
        Binding(
            get: { team.profileWorkerID.flatMap(team.worker) },
            set: { team.profileWorkerID = $0?.id }
        )
    }

    /// The first launch offers the two things there are to do. It invents no
    /// team, and it asks for no desktop permission: talking to a worker never
    /// needed one.
    private func firstLaunch(_ team: TeamModel) -> some View {
        ContentUnavailableView {
            Label("No team yet", systemImage: "person.2")
        } description: {
            Text("Create the first worker, then connect a model. Nothing is created for you, and no desktop permission is needed to talk to a worker.")
        } actions: {
            Button("Create the first worker") { team.isCreatingWorker = true }
                .buttonStyle(.borderedProminent)
            Button("Connect a model") { team.isShowingConnections = true }
        }
    }
}

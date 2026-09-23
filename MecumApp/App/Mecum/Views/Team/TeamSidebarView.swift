//
//  TeamSidebarView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI
import Workspace

/// TeamSidebarView lists the workspace, the team and the archive.
///
/// The rows are stable: their order comes from `TeamOutline` and nothing about
/// a worker's state reaches it, so a worker that starts or stops working stays
/// where it was. The archive is a section of its own, folded away, so removing
/// a worker from the active team does not remove it from the app.
///
/// The Hub and the meeting rooms belong above the team in the finished
/// sidebar. They are increment 3 and nothing stands in for them here. The
/// connections are a quiet footer rather than a toolbar button.
struct TeamSidebarView: View {

    /// The workspace has no stored name yet: there is one workspace per store
    /// directory and no entity to hold it. It gains a name when more than one
    /// can exist.
    private static let workspaceName = "Mecum"

    @Bindable
    var team: TeamModel

    @State private var showsArchive = false

    var body: some View {
        List(selection: $team.selection) {

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                    Text(Self.workspaceName)
                        .font(.headline)
                }
                .frame(minHeight: 28)
                .selectionDisabled()
            }

            Section {
                ForEach(team.rows) { row in
                    WorkerRowView(row: row)
                        .tag(row.id)
                        .contextMenu {
                            WorkerCommands(worker: row.worker, team: team)
                        }
                }
            } header: {
                HStack {
                    Text("Team")
                    Spacer()
                    Button("New worker", systemImage: "plus") { team.isCreatingWorker = true }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("New worker")
                        .keyboardShortcut("n", modifiers: .command)
                }
            }

            if !team.archived.isEmpty {
                Section(isExpanded: $showsArchive) {
                    ForEach(team.archived) { worker in
                        HStack(spacing: 8) {
                            MascotView(appearance: worker.appearance, size: 20)
                            Text(worker.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .help(worker.name)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(worker.name), archived")
                        .contextMenu {
                            WorkerCommands(worker: worker, team: team)
                        }
                    }
                } header: {
                    Text("Archive (\(team.archived.count))")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom, spacing: 0) { connectionsFooter }
    }

    /// The team's model connections, pinned at the foot of the sidebar so the
    /// team scrolls and it stays. The Team menu holds the same command.
    private var connectionsFooter: some View {
        Button {
            team.isShowingConnections = true
        } label: {
            Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help("The model connections the team uses")
    }
}

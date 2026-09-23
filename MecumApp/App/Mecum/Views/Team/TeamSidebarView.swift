//
//  TeamSidebarView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SwiftUI
import TeamShell
import Workspace

/// TeamSidebarView lists the team and the archive, under a title with the
/// button that adds a worker and above the connections.
///
/// Each worker is a block of its own (`SidebarBlock`), with a little space
/// between blocks, and the selected block is the selection: the list's own
/// highlight is off (`SidebarBridge`), and the block takes the accent colour
/// while the list has focus in the active window. The title, the blocks'
/// content and the footer share one inset. The workers stay one section, so
/// the arrow keys move from one to the next.
///
/// The rows are stable: their order comes from `TeamOutline` and nothing about
/// a worker's state reaches it, so a worker that starts or stops working stays
/// where it was. The archive is a section of its own, folded away, so removing
/// a worker from the active team does not remove it from the app.
///
/// Narrower than `ShellMetrics.sidebar.minimum`, whether the person dragged it
/// there or the shell made room for the inspector, the sidebar is compact: a
/// tile per worker with its mascot and name, the add button alone above them
/// and the connections as a symbol with its badge. It is never hidden.
///
/// The Hub and the meeting rooms belong above the team in the finished
/// sidebar. They are increment 3 and nothing stands in for them here.
struct TeamSidebarView: View {

    @Bindable
    var team: TeamModel

    @State private var showsArchive = false

    /// Decided from the width the split gives the sidebar; nothing here changes that width.
    @State private var isCompact = false

    @FocusState private var isListFocused: Bool

    @Environment(\.appearsActive)
    private var appearsActive

    var body: some View {
        List(selection: $team.selection) {
            ForEach(team.rows) { row in
                WorkerRowView(row: row, isCompact: isCompact, isSelected: team.selection == row.id,
                              isFocused: isListFocused && appearsActive)
                    .tag(row.id)
                    // A little more room between the title and the first block than between blocks.
                    .padding(.top, row.id == team.rows.first?.id ? 5 : 0)
                    .contextMenu {
                        WorkerCommands(worker: row.worker, team: team)
                    }
            }

            if !team.archived.isEmpty {
                Section(isExpanded: $showsArchive) {
                    ForEach(team.archived) { worker in
                        archivedRow(worker)
                    }
                } header: {
                    Text(isCompact ? "Archive" : "Archive (\(team.archived.count))")
                }
            }
        }
        .listStyle(.sidebar)
        .focused($isListFocused)
        .background(SidebarBridge())
        .onGeometryChange(for: Bool.self) { proxy in
            ShellMetrics.showsCompactTiles(sidebarWidth: proxy.size.width)
        } action: { isCompact in
            // At once, so the sidebar's minimum width never moves mid-change: an animated title and
            // footer made the split resize it back and forth until AppKit gave up on its constraints.
            self.isCompact = isCompact
        }
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .safeAreaBar(edge: .bottom, spacing: 0) { connectionsFooter }
    }

    // MARK: Title

    /// The sidebar's title and the button that adds a worker, at the trailing
    /// end of the same line as in a grouped form's header; alone and centred
    /// over the tiles.
    private var header: some View {
        HStack(spacing: 8) {
            if !isCompact {
                Text("Team")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            Button("New Worker", systemImage: "plus") { team.isCreatingWorker = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3.weight(.medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("New worker (Command-N)")
                .keyboardShortcut("n", modifiers: .command)
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, isCompact ? 0 : SidebarBlock.contentInset)
        // The plus sits about 6 points inside its 28 point frame, so its edge meets the badges' edge.
        .padding(.trailing, isCompact ? 0 : SidebarBlock.contentInset - 6)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: Archive

    /// An archived worker, quieter than the team: a small mascot and the name,
    /// or the mascot alone in the compact sidebar, with the name in its tooltip.
    private func archivedRow(_ worker: WorkerSnapshot) -> some View {
        HStack(spacing: 8) {
            MascotView(appearance: worker.appearance, size: 20)
            if !isCompact {
                Text(worker.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .padding(.horizontal, SidebarBlock.contentInset - SidebarBlock.listContentInset)
        .help(worker.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(worker.name), archived")
        .contextMenu {
            WorkerCommands(worker: worker, team: team)
        }
    }

    // MARK: Connections

    /// How many providers the last checks found ready. A provider not checked
    /// yet is not counted, since nothing is checked before the connections or
    /// a worker's profile are opened.
    private var readyConnections: Int {
        ModelProvider.allCases.count { team.connections.states[$0]?.isReady == true }
    }

    /// The team's model connections, pinned at the foot of the sidebar so the
    /// team scrolls and it stays, with the ready ones counted at the trailing
    /// edge. The Team menu holds the same command.
    private var connectionsFooter: some View {
        Button {
            team.isShowingConnections = true
        } label: {
            if isCompact {
                // The badge under the symbol, where a tile has its name.
                VStack(spacing: 4) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title3)
                    readyBadge
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 8) {
                    Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                    Spacer(minLength: 4)
                    readyBadge
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, isCompact ? 0 : SidebarBlock.contentInset)
        .padding(.vertical, 10)
        .help("The model connections the team uses")
        .accessibilityLabel("Connections")
        .accessibilityValue(readyDescription)
    }

    /// A green dot and the count of ready connections, in a quiet capsule; nothing while none is ready.
    @ViewBuilder
    private var readyBadge: some View {
        if readyConnections > 0 {
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("\(readyConnections)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minHeight: 18)
            .background(Capsule().fill(.quaternary))
            .accessibilityHidden(true)
        }
    }

    private var readyDescription: String {
        switch readyConnections {
        case 0:  ""
        case 1:  "1 connection ready"
        default: "\(readyConnections) connections ready"
        }
    }
}

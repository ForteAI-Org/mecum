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
/// between blocks, and the selected block is the selection, in the accent
/// colour while the sidebar has focus in the active window. The title, the
/// blocks' content and the footer share one inset.
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
/// The rows are a stack in a scroll view rather than a `List`, so SwiftUI lays
/// out every frame of them and the change to compact can morph each row into
/// its tile. The sidebar therefore does what the list did itself: a click
/// selects and focuses it, it is the key view before the conversation (so
/// Shift-Tab from the transcript reaches it), Up and Down move the selection
/// over the workers and then the open archive, and each row is a button for
/// assistive technology, marked selected when it is. The whole sidebar reports
/// no minimum width of its own, so its animated title and footer never move the
/// split column's minimum mid-change, which made AppKit stop the window with
/// its update-constraints loop.
///
/// The Hub and the meeting rooms belong above the team in the finished
/// sidebar. They are increment 3 and nothing stands in for them here.
struct TeamSidebarView: View {

    @Bindable
    var team: TeamModel

    @State private var showsArchive = false

    /// Decided from the width the split gives the sidebar; nothing here changes that width.
    @State private var isCompact = false

    @FocusState private var isFocused: Bool

    @Environment(\.appearsActive)
    private var appearsActive

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(team.rows) { row in
                        workerRow(row)
                    }
                    if !team.archived.isEmpty {
                        archive
                    }
                }
                .padding(.horizontal, SidebarBlock.gutter)
            }
            .focusable(interactions: .edit)
            .focused($isFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                moveSelection(direction, scroller: scroller)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Team")
        .background(SidebarBridge())
        .onGeometryChange(for: Bool.self) { proxy in
            ShellMetrics.showsCompactTiles(sidebarWidth: proxy.size.width)
        } action: { isCompact in
            withAnimation(motion) { self.isCompact = isCompact }
        }
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .safeAreaBar(edge: .bottom, spacing: 0) { connectionsFooter }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    /// The change to compact and back, and the archive folding; nothing moves under Reduce Motion.
    private var motion: Animation? {
        reducesMotion ? nil : .smooth(duration: 0.3)
    }

    // MARK: Selection

    /// Makes `id` the selection and gives the sidebar focus, as a click on a list row does.
    private func select(_ id: UUID) {
        team.selection = id
        isFocused = true
    }

    /// The rows Up and Down step through, in the order they are shown.
    private var navigableIDs: [UUID] {
        team.rows.map(\.id) + (showsArchive ? team.archived.map(\.id) : [])
    }

    /// Up and Down select the row above or below and stop at either end; with
    /// nothing selected, Down starts at the first row and Up at the last.
    private func moveSelection(_ direction: MoveCommandDirection, scroller: ScrollViewProxy) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        let current = team.selection.flatMap(ids.firstIndex(of:))
        let next: Int
        switch direction {
        case .down: next = current.map { min($0 + 1, ids.count - 1) } ?? 0
        case .up:   next = current.map { max($0 - 1, 0) } ?? ids.count - 1
        default:    return
        }
        team.selection = ids[next]
        scroller.scrollTo(ids[next])
    }

    private func workerRow(_ row: TeamRow) -> some View {
        WorkerRowView(row: row, isCompact: isCompact, isSelected: team.selection == row.id,
                      isFocused: isFocused && appearsActive)
            // A little more room between the title and the first block than between blocks.
            .padding(.top, row.id == team.rows.first?.id ? 5 : 0)
            .contentShape(Rectangle())
            .onTapGesture { select(row.id) }
            .accessibilityAction { select(row.id) }
            .contextMenu {
                WorkerCommands(worker: row.worker, team: team)
            }
            .id(row.id)
    }

    // MARK: Title

    /// The sidebar's title and the button that adds a worker, at the trailing
    /// end of the same line as in a grouped form's header; alone and centred
    /// over the tiles.
    private var header: some View {
        ZStack {
            // Laid out in both widths and faded, so the change never squeezes it into a column.
            Text("Team")
                .font(.title3.weight(.semibold))
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, SidebarBlock.contentInset)
                .opacity(isCompact ? 0 : 1)
                // Gone before the plus crosses it, and back once the plus has passed.
                .animation(
                    reducesMotion ? nil : (isCompact ? .easeOut(duration: 0.1) : .easeIn(duration: 0.15).delay(0.15)),
                    value: isCompact
                )
                .accessibilityHidden(isCompact)
                .accessibilityAddTraits(.isHeader)
            Button("New Worker", systemImage: "plus") { team.isCreatingWorker = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3.weight(.medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("New worker (Command-N)")
                .keyboardShortcut("n", modifiers: .command)
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .trailing)
                // The plus sits about 6 points inside its 28 point frame, so its edge meets the badges' edge.
                .padding(.trailing, isCompact ? 0 : SidebarBlock.contentInset - 6)
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: Archive

    /// The archive's title, which folds and unfolds it, and its rows while unfolded.
    private var archive: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(motion) { showsArchive.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(isCompact ? "Archive" : "Archive (\(team.archived.count))")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showsArchive ? 90 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, isCompact ? 0 : SidebarBlock.contentInset - SidebarBlock.gutter)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityValue(showsArchive ? "Expanded" : "Collapsed")

            if showsArchive {
                ForEach(team.archived) { worker in
                    archivedRow(worker)
                }
            }
        }
    }

    /// An archived worker, quieter than the team: a small mascot and the name,
    /// or the mascot alone in the compact sidebar, with the name in its tooltip.
    /// It has no block of its own, only the selection's while it is selected.
    private func archivedRow(_ worker: WorkerSnapshot) -> some View {
        let isSelected   = team.selection == worker.id
        let isEmphasized = isSelected && isFocused && appearsActive
        return HStack(spacing: 8) {
            MascotView(appearance: worker.appearance, size: 20)
            if !isCompact {
                Text(worker.name)
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: isCompact ? .center : .leading)
        .padding(.horizontal, SidebarBlock.contentInset - SidebarBlock.gutter)
        .background {
            if isSelected { SidebarBlock(isSelected: true, isEmphasized: isEmphasized) }
        }
        .padding(.vertical, SidebarBlock.spacing / 2)
        .contentShape(Rectangle())
        .onTapGesture { select(worker.id) }
        .help(worker.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(worker.name), archived")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(worker.id) }
        .contextMenu {
            WorkerCommands(worker: worker, team: team)
        }
        .id(worker.id)
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
            // One layout, as a worker's row. Compact, the badge sits under the symbol, where a tile
            // has its name.
            let layout = isCompact ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(isCompact ? .title3 : .body)
                if !isCompact {
                    Text("Connections")
                        .fixedSize()
                        // Leaving at once: a fading copy was drawn at the top of the sidebar during a resize.
                        .transition(reducesMotion ? .identity : .asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.15)),
                            removal  : .identity
                        ))
                    Spacer(minLength: 4)
                }
                readyBadge
            }
            // As on a row: the badge's number moves with its capsule instead of fading apart from it.
            .contentTransition(.identity)
            .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            .contentShape(Rectangle())
        }
        // Plain, so SwiftUI draws the label and moves its parts; a borderless one cross-faded it whole.
        .buttonStyle(.plain)
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

//
//  TeamSidebarView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

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
struct TeamSidebarView: View, Equatable {
    
    @Bindable
    var team: TeamModel

    @State private var showsArchive = false

    /// What the search field holds; empty shows every worker.
    @State private var query = ""

    @AppStorage(AppPreferences.sidebarShowsSearch)
    private var showsSearch = AppPreferences.sidebarShowsSearchDefault

    /// Decided from the width the split gives the sidebar; nothing here changes that width.
    @State private var isCompact = false

    @FocusState private var isFocused: Bool

    @Environment(\.appearsActive)
    private var appearsActive

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion
    
    static func == (
        lhs: borrowing TeamSidebarView,
        rhs: borrowing TeamSidebarView
        
    ) -> Bool {
        lhs.isFocused == rhs.isFocused
    }

    var body: some View {
        
        ScrollViewReader { scroller in
            ScrollView {
            
                VStack(spacing: 0) {
                    ForEach(visibleRows) { row in
                        workerRow(row)
                    }

                    if isSearching, visibleRows.isEmpty {
                        Text("No worker matches “\(query)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(
                                maxWidth : .infinity,
                                alignment: .leading
                            )
                            .padding(
                                .horizontal,
                                SidebarBlock.contentInset - SidebarBlock.gutter
                            )
                            .padding(
                                .top,
                                12
                            )
                    }

                    // The archive is left out while searching: the search finds the team's own workers.
                    if !team.archived.isEmpty, !isSearching {
                        TeamSidebarArchive(
                            team        : team,
                            showsArchive: $showsArchive,
                            isCompact   : isCompact,
                            isFocused   : isFocused && appearsActive,
                            motion      : motion,
                            select      : select
                        )
                    }
                }
                .padding(
                    .horizontal,
                    SidebarBlock.gutter
                )
            }
            .focusable(interactions: .edit)
            .focused($isFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                moveSelection(
                    direction,
                    scroller: scroller
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Team")
        .background(SidebarBridge())
        .onGeometryChange(for: Bool.self) { proxy in
            ShellMetrics.showsCompactTiles(
                sidebarWidth: proxy.size.width
            )
        } action: { isCompact in
            withAnimation(motion) { self.isCompact = isCompact }
        }
        .toolbar {
            
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }
            
            ToolbarItem {
                Button(
                    "New Worker",
                    systemImage: "plus"
                ) {
                    team.isCreatingWorker = true
                }
            }
            
        }
//        .safeAreaBar(
//            edge   : .top,
//            spacing: 0
//        ) {
//            TeamSidebarHeader(
//                team     : team,
//                isCompact: isCompact
//            )
//        }
        .edgeBar(
            edge   : .top,
            spacing: 0
        ) {
            searchBar
        }
        // A search the field no longer shows would hide workers with nothing to say why.
        .onChange(of: isCompact) {
            if isCompact { query = "" }
        }
        .onChange(of: showsSearch) {
            if !showsSearch { query = "" }
        }
        .edgeBar(
            edge   : .bottom,
            spacing: 0
        ) {
            TeamSidebarFooter(
                team     : team,
                isCompact: isCompact
            )
        }
        .frame(
            minWidth: 0,
            maxWidth: .infinity
        )
    }

    /// The change to compact and back, and the archive folding; nothing moves under Reduce Motion.
    private var motion: Animation? {
        reducesMotion ? nil : .smooth(duration: 0.3)
    }

    // MARK: Selection

    /// Makes `id` the selection and gives the sidebar focus, as a click on a list row does.
    private func select(_ id: UUID) {
        team.selection = id
        isFocused      = true
    }

    /// The rows Up and Down step through, in the order they are shown.
    private var navigableIDs: [UUID] {
        visibleRows.map(\.id) + (showsArchive && !isSearching ? team.archived.map(\.id) : [])
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The team's workers, or those the search finds by name or role.
    private var visibleRows: [TeamRow] {
        guard isSearching else { return team.rows }

        let words = query.trimmingCharacters(in: .whitespaces)
        return team.rows.filter { $0.matches(words) }
    }

    /// The search field at the top of the full sidebar, when Settings keeps it.
    @ViewBuilder
    private var searchBar: some View {
        if showsSearch, !isCompact {
            SidebarSearchField(text: $query)
                .padding(
                    .horizontal,
                    SidebarBlock.gutter + 4
                )
                .padding(
                    .vertical,
                    6
                )
        }
    }

    /// Up and Down select the row above or below and stop at either end; with
    /// nothing selected, Down starts at the first row and Up at the last.
    private func moveSelection(
        _ direction: MoveCommandDirection,
        scroller   : ScrollViewProxy
    ) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }

        let current = team.selection.flatMap(ids.firstIndex(of:))
        let next: Int
        switch direction {
        case .down:
            next = current.map {
                min(
                    $0 + 1,
                    ids.count - 1
                )
            } ?? 0

        case .up:
            next = current.map {
                max(
                    $0 - 1,
                    0
                )
            } ?? ids.count - 1

        default:
            return
        }

        team.selection = ids[next]
        scroller.scrollTo(ids[next])
    }

    private func workerRow(_ row: TeamRow) -> some View {
        WorkerRowView(
            row       : row,
            isCompact : isCompact,
            isSelected: team.selection == row.id,
            isFocused : isFocused && appearsActive
        )
        // A little more room between the title and the first block than between blocks.
        .padding(
            .top,
            row.id == visibleRows.first?.id ? 5 : 0
        )
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .accessibilityAction { select(row.id) }
        .contextMenu {
            WorkerCommands(
                worker: row.worker,
                team  : team
            )
        }
        .id(row.id)
    }
}

//
//  TeamShellView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI
import TeamShell
import Workspace

/// TeamShellView is the team window once the workspace is open (§3.1): a two
/// column split of the team and the selected worker's conversation, and a
/// hideable inspector beside the conversation.
///
/// The conversation takes what is left and is never divided. The columns are
/// laid out at `ShellMetrics`'s constant widths, and each column reports a
/// constant minimum, never one its own layout produced. Whether the inspector
/// is shown is decided from the window's frame (`WindowWidthReader`), outside
/// the split, so showing or hiding it cannot change the width it was decided
/// from: a restored request that does not fit is resolved once, when the
/// window first reports, and a resize closes it first and brings it back only
/// with `ShellMetrics.hysteresis` to spare. Opening it on request in a window
/// too narrow for both columns hides the sidebar instead.
///
/// The request is the window's own memory, passed in as a binding, so the
/// offscreen snapshot hosts this view without a scene. The column widths a
/// person drags are the split view's to restore with the window.
struct TeamShellView: View {

    @Bindable
    var team: TeamModel

    @Binding var isInspectorRequested: Bool

    @State private var columns: NavigationSplitViewVisibility

    /// The window's width as AppKit last reported it, nil before the first report.
    @State private var windowWidth: Double?

    @State private var isInspectorShown = false

    /// `columns` is where the split starts; the snapshot passes what the
    /// inspector toggle would have left.
    init(
        team                : TeamModel,
        isInspectorRequested: Binding<Bool>,
        columns             : NavigationSplitViewVisibility = .all
    ) {
        self.team             = team
        _isInspectorRequested = isInspectorRequested
        _columns              = State(initialValue: columns)
    }

    private var isSidebarShown: Bool { columns != .detailOnly }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            TeamSidebarView(team: team)
                .navigationSplitViewColumnWidth(
                    min  : ShellMetrics.sidebar.minimum,
                    ideal: ShellMetrics.sidebar.ideal,
                    max  : ShellMetrics.sidebar.maximum
                )
        } detail: {
            detail
                .overlay(alignment: .top) { header }
                .navigationTitle(ShellChrome.windowTitle(for: team.selectedWorker))
                // A constant zero minimum for the column: the conversation's own height follows its width,
                // and a real minimum width would make AppKit grow the window rather than close the inspector.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .inspector(isPresented: inspectorPresentation) {
                    inspector
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .inspectorColumnWidth(
                            min  : ShellMetrics.inspector.minimum,
                            ideal: ShellMetrics.inspector.ideal,
                            max  : ShellMetrics.inspector.maximum
                        )
                }
        }
        .background(WindowWidthReader(onWidth: windowResized))
        .onChange(of: columns) { reconsiderInspector() }
        .onChange(of: team.selection) {
            Task { await team.openSelectedConversation() }
        }
        .sheet(isPresented: $team.isCreatingWorker) {
            NewWorkerSheet(team: team)
        }
        .sheet(isPresented: $team.isShowingConnections) {
            ConnectionsSheet(connections: team.connections)
        }
        .sheet(item: profileWorker) { worker in
            WorkerProfileSheet(team: team, worker: worker)
        }
        .toolbar { toolbar }
        // The window keeps the worker's name for Mission Control and the Window menu; the header shows it.
        .toolbar(removing: .title)
        .focusedSceneValue(\.team, team)
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

    // MARK: Toolbar

    /// The window's own controls, `ShellChrome.toolbar`: the split view's sidebar
    /// toggle and the inspector toggle. The worker's name is the floating header,
    /// the connections are at the foot of the sidebar, and Release the computer is
    /// in the composer beside Send and in the worker's commands.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button(isInspectorShown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing",
                   action: toggleInspector)
                .keyboardShortcut("i", modifiers: [.control, .option, .command])
                .help("Show or hide the inspector (Control-Option-Command-I)")
        }
    }

    /// Closes a shown inspector, or opens it, hiding the sidebar when that is
    /// what makes room. A request the window cannot hold yet is kept.
    private func toggleInspector() {
        guard !isInspectorShown else {
            isInspectorRequested = false
            isInspectorShown     = false
            return
        }
        isInspectorRequested = true
        guard let windowWidth else { return }
        if isSidebarShown, ShellMetrics.openingHidesSidebar(window: windowWidth) {
            columns = .detailOnly
        }
        isInspectorShown = ShellMetrics.fitsInspector(window: windowWidth, isSidebarShown: columns != .detailOnly)
    }

    /// The header's action: shows the worker's details, which for now are the
    /// inspector. An inspector already shown stays shown.
    private func showDetails() {
        guard !isInspectorShown else { return }
        toggleInspector()
    }

    /// The first report resolves a restored request once; later ones apply the
    /// resize rule, whose hysteresis keeps a jittering resize from flipping it.
    private func windowResized(to width: Double) {
        let isFirst = windowWidth == nil
        guard width != windowWidth else { return }
        windowWidth = width
        guard isInspectorRequested else { return }
        isInspectorShown = isFirst
            ? ShellMetrics.fitsInspector(window: width, isSidebarShown: isSidebarShown)
            : ShellMetrics.showsInspectorAfterResize(window: width, isSidebarShown: isSidebarShown,
                                                     isShown: isInspectorShown)
    }

    /// The person showed or hid the sidebar: a sidebar that comes back closes
    /// an inspector that no longer fits, and one that goes may make room.
    private func reconsiderInspector() {
        guard let windowWidth, isInspectorRequested else { return }
        isInspectorShown = ShellMetrics.fitsInspector(window: windowWidth, isSidebarShown: isSidebarShown)
    }

    /// What the inspector shows, and a close from the inspector's own edge.
    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { isInspectorShown },
            set: { isShown in
                guard !isShown else { return }
                isInspectorRequested = false
                isInspectorShown     = false
            }
        )
    }

    // MARK: Areas

    @ViewBuilder
    private var detail: some View {
        if let worker = team.selectedWorker {
            WorkerConversationView(team: team, worker: worker)
        } else if team.active.isEmpty && team.archived.isEmpty {
            firstLaunch
        } else {
            ContentUnavailableView(
                "No worker selected",
                systemImage: "person.crop.circle",
                description: Text("Choose a worker in the team to open its conversation.")
            )
        }
    }

    @ViewBuilder
    private var header: some View {
        if let header = ShellChrome.header(for: team.selectedWorker) {
            WorkerHeaderView(header: header, open: showDetails)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let worker = team.selectedWorker {
            WorkerInspectorView(team: team, worker: worker)
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "sidebar.trailing",
                description: Text("Select a worker to see what it is doing and the model its last turn ran with.")
            )
        }
    }

    /// The worker being edited, as the sheet's item. Closing the sheet clears it.
    private var profileWorker: Binding<WorkerSnapshot?> {
        Binding(
            get: { team.profileWorkerID.flatMap(team.worker) },
            set: { team.profileWorkerID = $0?.id }
        )
    }

    /// The first launch offers the two things there are to do. It invents no
    /// team, and it asks for no desktop permission: talking to a worker never
    /// needed one.
    private var firstLaunch: some View {
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

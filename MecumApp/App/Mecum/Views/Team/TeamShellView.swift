//
//  TeamShellView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// TeamShellView is the team window once the workspace is open (§3.1): a two
/// column split of the team and the selected worker's conversation, and a
/// hideable inspector beside the conversation.
///
/// The sidebar is never hidden. There is no toggle for it, the View menu has
/// no command for it (`MecumApp`), `SidebarBridge` stops a drag at the compact
/// width, and any other path that hides it is undone by the guard on `columns`.
/// It turns compact instead, when the person drags it narrow or when the window
/// needs the room for the inspector.
///
/// The conversation takes what is left and is never divided. The columns are
/// laid out at `ShellMetrics`'s constant widths, and each column reports a
/// constant minimum, never one its own layout produced. How the window is
/// divided is decided from its frame (`WindowWidthReader`), outside the split,
/// so showing the inspector or compacting the sidebar cannot change the width
/// it was decided from: a restored request is resolved once, when the window
/// first reports, and a resize changes the division first and restores it
/// only with `ShellMetrics.hysteresis` to spare.
///
/// A new division is applied in two steps, so the split never asks the window
/// for more width than it has and the window never grows on its own: what
/// gives room first (the sidebar turning compact, the inspector closing), and
/// what takes it after (the inspector opening, the sidebar widening). The
/// inspector closes over about a quarter of a second while the sidebar widens
/// at once, so the second step waits `inspectorClosing` after a close.
///
/// The request is the window's own memory, passed in as a binding, so the
/// offscreen snapshot hosts this view without a scene. The column widths a
/// person drags are the split view's to restore with the window, and one the
/// person dragged is also the width the sidebar returns to from compact.
struct TeamShellView: View {

    /// Longer than AppKit takes to close the inspector column: 250 ms, measured on macOS 26.
    private static let inspectorClosing = Duration.milliseconds(300)

    /// Long enough for the split to lay out the compact sidebar before the inspector opens beside it.
    private static let sidebarCompacting = Duration.milliseconds(50)

    @Bindable
    var team: TeamModel

    @Binding var isInspectorRequested: Bool

    /// Always `.all`: the guard below puts back anything else.
    @State private var columns = NavigationSplitViewVisibility.all

    /// The window's width as AppKit last reported it, nil before the first report.
    @State private var windowWidth: Double?

    /// What the window shows now, which lags `target` while a division is applied in two steps.
    @State private var division = ShellMetrics.Division.withoutInspector

    /// What the rule last decided, which a resize compares against.
    @State private var target = ShellMetrics.Division.withoutInspector

    /// The second step of the division being applied, cancelled by a newer one.
    @State private var secondStep: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    init(
        team                : TeamModel,
        isInspectorRequested: Binding<Bool>
    ) {
        self.team             = team
        _isInspectorRequested = isInspectorRequested
    }

    var body: some View {
        
        NavigationSplitView(columnVisibility: $columns) {
            TeamSidebarView(team: team)
                .toolbar(removing: .sidebarToggle)
                // Outermost, since under another modifier the split reads no width at all.
                // A change of these values moves the column to `ideal`, which is how it turns compact and back.
                .navigationSplitViewColumnWidth(
                    min  : ShellMetrics.compactSidebar,
                    ideal: division.isSidebarCompact ? ShellMetrics.compactSidebar : ShellMetrics.sidebar.ideal,
                    max  : division.isSidebarCompact ? ShellMetrics.compactSidebar : ShellMetrics.sidebar.maximum
                )
        } detail: {
            detail
                .navigationTitle(ShellChrome.windowTitle(for: team.selectedWorker))
                .toolbar { toolbar }
                // A constant zero minimum for the column: the conversation's own height follows its width,
                // and a real minimum width would make AppKit grow the window rather than close the inspector.
                .frame(
                    minWidth : 0,
                    maxWidth : .infinity,
                    minHeight: 0,
                    maxHeight: .infinity
                )
                .inspector(isPresented: inspectorPresentation) {
                    inspector
                        .frame(
                            minWidth : 0,
                            maxWidth : .infinity,
                            minHeight: 0,
                            maxHeight: .infinity
                        )
                        .inspectorColumnWidth(
                            min  : ShellMetrics.inspector.minimum,
                            ideal: ShellMetrics.inspector.ideal,
                            max  : ShellMetrics.inspector.maximum
                        )
                }
        }
        .background(WindowWidthReader(onWidth: windowResized))
        .onChange(of: columns) {
            if columns != .all { columns = .all }
        }
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
            WorkerProfileSheet(
                team  : team,
                worker: worker
            )
        }
        // The window keeps the worker's name for Mission Control and the Window menu; the header shows it.
        .toolbar(removing: .title)
        .focusedSceneValue(
            \.team,
            team
        )
        .alert(
            "That could not be done",
            isPresented: Binding(
                get: { team.problem != nil },
                set: { if !$0 { team.problem = nil } }
            )
        ) {
            Button(
                "OK",
                role: .cancel
            ) {}
        } message: {
            Text(team.problem ?? "")
        }
    }

    // MARK: Toolbar

    /// The window's own controls, `ShellChrome.toolbar`: the worker's header at
    /// the leading edge, and the screen and inspector toggles at the trailing edge. The
    /// connections are at the foot of the sidebar, and Release the computer is
    /// in the composer beside Send and in the worker's commands.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The worker's name leads the conversation's side of the bar, in place of a title,
        // without the glass a macOS 26 toolbar gives its items.
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { header }
                .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .navigation) { header }
        }

        ToolbarItem {
            Toggle(isOn: screenOverConversation) {
                Label(
                    "Screen Over the Conversation",
                    systemImage: "display"
                )
            }
            .toggleStyle(.button)
            .disabled(!hasScreen)
            .help("Show the worker's screen over the conversation, or put it back in the inspector")
        }

        ToolbarItem {
            Button(
                target.isInspectorShown ? "Hide Inspector" : "Show Inspector",
                systemImage: "info.circle",
                action     : toggleInspector
            )
            .keyboardShortcut(
                "i",
                modifiers: [.control, .option, .command]
            )
            .help("Show or hide the inspector (Control-Option-Command-I)")
        }
    }

    /// True while the selected worker has a screen to watch, which is when the screen toggle works.
    private var hasScreen: Bool {
        team.selection.map(team.hasScreen) ?? false
    }

    /// The screen at the top right of the conversation, or in the inspector; the change is animated.
    private var screenOverConversation: Binding<Bool> {
        Binding(
            get: { team.showsScreenInConversation },
            set: { shows in withAnimation(.snappy) { team.showsScreenInConversation = shows } }
        )
    }

    /// Closes a shown inspector and gives the sidebar back its width, or opens
    /// it, compacting the sidebar when that is what makes room. A request the
    /// window cannot hold yet is kept.
    private func toggleInspector() {
        guard !target.isInspectorShown else {
            isInspectorRequested = false
            divide(into: .withoutInspector)
            return
        }

        isInspectorRequested = true
        guard let windowWidth else { return }

        divide(into: ShellMetrics.division(
            window  : windowWidth,
            previous: nil
        ))
    }

    /// The first report resolves a restored request once; later ones apply the
    /// resize rule, whose hysteresis keeps a jittering resize from flipping it.
    private func windowResized(to width: Double) {
        let isFirst = windowWidth == nil
        guard width != windowWidth else { return }

        windowWidth = width
        guard isInspectorRequested else { return }

        divide(into: ShellMetrics.division(
            window  : width,
            previous: isFirst ? nil : target
        ))
    }

    /// Applies `next` in two steps: at once what gives room, then, after the
    /// split has made it, what takes room. A newer division cancels the second
    /// step of an older one and starts from what is shown.
    private func divide(into next: ShellMetrics.Division) {
        secondStep?.cancel()
        target = next

        let first = ShellMetrics.Division(
            isInspectorShown: division.isInspectorShown && next.isInspectorShown,
            isSidebarCompact: division.isSidebarCompact || next.isSidebarCompact
        )
        let wait  = division.isInspectorShown && !first.isInspectorShown ? Self.inspectorClosing
                                                                         : Self.sidebarCompacting
        division = first
        guard first != next else { return }

        secondStep = Task {
            // A cancelled wait belongs to a division that a newer one replaced.
            do { try await Task.sleep(for: wait) } catch { return }
            division = next
        }
    }

    /// What the inspector shows, and a close from the inspector's own edge.
    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { division.isInspectorShown },
            set: { isShown in
                guard !isShown else { return }

                isInspectorRequested = false
                divide(into: .withoutInspector)
            }
        )
    }

    // MARK: Areas

    @ViewBuilder
    private var detail: some View {
        if let worker = team.selectedWorker {
            WorkerConversationView(
                team  : team,
                worker: worker
            )
        } else if team.active.isEmpty && team.archived.isEmpty {
            FirstLaunchView(team: team)
        } else {
            ContentUnavailableView(
                "No worker selected",
                systemImage: "person.crop.circle",
                description: Text("Choose a worker in the team to open its conversation.")
            )
        }
    }

    /// The selected worker's name and mascot; another worker's replace them with the system's
    /// blur, so the two names never sit legibly on top of each other.
    private var header: some View {
        ZStack(alignment: .leading) {
            if let header = ShellChrome.header(for: team.selectedWorker) {
                WorkerHeaderView(header: header)
                    .id(header.workerID)
                    .transition(reducesMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }
        }
        .animation(
            reducesMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.25),
            value: team.selection
        )
    }

    @ViewBuilder
    private var inspector: some View {
        if let worker = team.selectedWorker {
            WorkerInspectorView(
                team  : team,
                worker: worker
            )
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "info.circle",
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
}

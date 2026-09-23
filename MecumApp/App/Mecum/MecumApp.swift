
import SwiftUI

@main
struct MecumApp: App {

    /// The window the desktop lab lives in, opened from the Window menu.
    static let labWindowID = "desktop-lab"

    @State private var model = AppModel()

    /// The workspace database, which the team window reads. It is opened here
    /// so a store that cannot open says so at launch rather than at the first
    /// click.
    @State private var workspace = WorkspaceLaunch()
    @NSApplicationDelegateAdaptor(SeatReleasingDelegate.self) private var delegate

    var body: some Scene {

        // The team is the front door. It holds no seat and needs no grant.
        WindowGroup("Mecum") {
            TeamWindowView(launch: workspace, connections: model.settings, didOpenTeam: { delegate.teams.add($0) })
                // The delegate is made by AppKit and the model by SwiftUI, so
                // this window, the one that always exists, is where they meet.
                .task { delegate.model = model }
        }
        .commands { LabWindowCommands() }

        // The desktop lab, reachable on its own. Opening it is what asks for
        // the desktop grants and starts the watchers; launching does not.
        Window("Desktop Lab", id: Self.labWindowID) {
            NavigationStack {
                ContentView(model: model)
            }
            .task { model.startDesktopSurface() }
        }

        Settings {
            SettingsView(store: model.settings)
        }
    }
}

/// Quitting gives the seat back and keeps what was typed.
///
/// Nothing else gives the seat back. A window the seat took is on a background
/// display this process owns, and a process that exits without releasing
/// leaves that window somewhere the person cannot reach and the display up
/// until the window server notices the owner is gone. Command-Q was that exit.
///
/// A draft reaches the store only once typing pauses, so a draft typed just
/// before Command-Q is still only in memory. Each open team's draft is written
/// before the seat is closed, so a draft survives the relaunch.
///
/// AppKit asks this question synchronously, which is why the answer is
/// `terminateLater` and the reply goes out once the writes and the close have
/// returned. Each wait is bounded, because the alternative is worse than a lost
/// draft or a stranded window: a write or a teardown that never returns would
/// turn Quit into a hang. At the limit the reply goes out anyway and the
/// process exits with whatever was managed. Nothing to write and a seat that
/// is already ended answer `terminateNow` and cost nothing.
@MainActor
final class SeatReleasingDelegate: NSObject, NSApplicationDelegate {

    var model: AppModel?

    /// Every team window's model, held weakly: a closed window's team goes
    /// with it.
    let teams = NSHashTable<TeamModel>.weakObjects()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let drafts    = teams.allObjects.filter(\.hasUnsavedDraft)
        let agents    = teams.allObjects.filter(\.hasAgentHosts)
        let seatOwner = model?.session == nil ? nil : model
        guard !drafts.isEmpty || !agents.isEmpty || seatOwner != nil else { return .terminateNow }
        Task { @MainActor in
            await Self.bounded(.seconds(2)) {
                for team in drafts { await team.flushDraft() }
            }
            await Self.bounded(.seconds(5)) {
                for team in agents { await team.closeAgentHosts() }
            }
            if let seatOwner {
                await Self.bounded(.seconds(5)) { await seatOwner.closeSession() }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Runs `work` and stops waiting for it at `limit`, whichever comes first.
    ///
    /// The work runs in its own task rather than a task group's child, because
    /// a group does not return before every child has, and a write that ignores
    /// cancellation would then hold Quit for as long as it takes. At the limit
    /// the work is cancelled and left behind; the process is about to exit.
    private static func bounded(
        _ limit: Duration,
        _ work : @escaping @Sendable @MainActor () async -> Void
    ) async {
        let (ended, end) = AsyncStream<Void>.makeStream()
        let worker = Task { @MainActor in
            await work()
            end.finish()
        }
        let timer = Task {
            // Cancelled when the work ends first; the wait ends either way.
            do { try await Task.sleep(for: limit) } catch {}
            end.finish()
        }
        for await _ in ended {}
        worker.cancel()
        timer.cancel()
    }
}

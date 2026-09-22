
import SwiftUI

@main
struct MecumApp: App {
    @State private var model = AppModel()
    /// The workspace database. Nothing reads it yet: the team sidebar and the
    /// conversation are T3. It is opened here so a store that cannot open says
    /// so at launch rather than at the first click.
    @State private var workspace = WorkspaceLaunch()
    @NSApplicationDelegateAdaptor(SeatReleasingDelegate.self) private var delegate

    var body: some Scene {

        WindowGroup("Mecum") {
            NavigationStack {
                ContentView(model: model)
            }
            // The delegate is made by AppKit and the model by SwiftUI, so this
            // is where the two meet. Quitting is all it uses the model for.
            .task {
                delegate.model = model
                workspace.open()
            }
        }

        Settings {
            SettingsView(store: model.settings)
        }
    }
}

/// Quitting gives the seat back.
///
/// Nothing else does. A window the seat took is on a background display this
/// process owns, and a process that exits without releasing leaves that window
/// somewhere the person cannot reach and the display up until the window server
/// notices the owner is gone. Command-Q was that exit.
///
/// AppKit asks this question synchronously, which is why the answer is
/// `terminateLater` and the reply goes out once the close has returned. The
/// wait is bounded, because the alternative is worse than a stranded window: a
/// teardown that never returns would turn Quit into a hang. At the limit the
/// reply goes out anyway and the process exits with whatever the teardown
/// managed. A seat that is already ended answers `terminateNow` and costs
/// nothing.
@MainActor
final class SeatReleasingDelegate: NSObject, NSApplicationDelegate {

    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.session != nil else { return .terminateNow }
        Task { @MainActor in
            await Self.bounded(.seconds(5)) { await model.closeSession() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Runs `work` and stops waiting for it at `limit`, whichever comes first.
    private static func bounded(
        _ limit: Duration,
        _ work : @escaping @Sendable @MainActor () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }
}

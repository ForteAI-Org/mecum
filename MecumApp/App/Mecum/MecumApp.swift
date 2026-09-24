//
//  MecumApp.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SeatBroker
import SwiftUI

@main
struct MecumApp: App {

    @State private var model = AppModel()

    /// The workspace database, which the team window reads. It is opened here
    /// so a store that cannot open says so at launch rather than at the first
    /// click.
    @State private var workspace = WorkspaceLaunch()

    @NSApplicationDelegateAdaptor(SeatReleasingDelegate.self)
    private var delegate

    /// A snapshot or window check run, which draws its own windows and quits,
    /// or the host of the unit tests, which must not open the person's workspace either.
    static var isCheckRun: Bool {
        WindowSnapshots.isRequested
            || WindowResizeCheck.isRequested
            || TranscriptCopyCheck.isRequested
            || WindowClickCheck.isRequested
            || isTestHost
    }

    /// The app launched by `xcodebuild test` to host `MecumTests`.
    static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment

        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains {
            environment[$0] != nil
        }
    }

    init() {
        // A restored team window would open the person's workspace; a snapshot run must not.
        if Self.isCheckRun { UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true]) }
    }

    var body: some Scene {

        // The team is the front door. It asks for no grant until a worker first opens an app.
        WindowGroup("Mecum") {
            TeamWindowView(
                launch     : workspace,
                connections: model.settings,
                broker     : model.broker,
                didOpenTeam: { delegate.teams.add($0) }
            )
            // The delegate is made by AppKit and the model by SwiftUI, so
            // this window, the one that always exists, is where they meet.
            .task { delegate.model = model }
        }
        // A snapshot run draws offscreen and quits; it opens no window and no workspace.
        .defaultLaunchBehavior(Self.isCheckRun ? .suppressed : .automatic)
        .commands {
            // The team's sidebar turns compact and is never hidden, so the View menu has no place for it.
            CommandGroup(replacing: .sidebar) {}
            TextSizeCommands()
            TeamMenuCommands()
        }

        Settings {
            SettingsView(store: model.settings)
        }
    }
}

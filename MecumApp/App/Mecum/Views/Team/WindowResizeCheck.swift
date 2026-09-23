//
//  WindowResizeCheck.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI
import TeamShell
import Workspace

/// WindowResizeCheck puts the team shell in a real window on screen, with a real display cycle,
/// and resizes it back and forth across the widths where the sidebar turns compact and where the
/// inspector stops fitting, when the app is launched with MECUM_WINDOW_CHECK=1. It prints each
/// step and quits with 0 once every step has run; an abort in AppKit's layout ends the process
/// first, with its own exit status.
///
/// It opens at 900 by 612 with the inspector requested, the sidebar shown and a worker selected,
/// which is what the restored window that aborted had. The team is `WindowSnapshots`'s synthetic
/// one, in a temporary store; the person's workspace is never opened.
@MainActor
enum WindowResizeCheck {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["MECUM_WINDOW_CHECK"] == "1" }

    /// The widths stepped through: around the full sidebar's line (1100), the compact one (912) and back.
    private static let widths: [Double] = [900, 1150, 1090, 1110, 1099, 1101, 1130, 980, 1105, 912, 911, 940,
                                           1250, 900]

    static func runAndQuit() async {
        let store = URL.temporaryDirectory.appending(path: "MecumWindowCheck-\(UUID().uuidString)",
                                                     directoryHint: .isDirectory)
        var status: Int32 = 0
        do {
            let team = try await WindowSnapshots.syntheticTeam(in: store)
            for name in ["Atlas", "Nova"] {
                team.selection = team.rows.first { $0.name == name }?.id
                await team.openSelectedConversation()
                try await check(team, selected: name)
            }
            print("window check: every step ran without an abort")
        } catch {
            FileHandle.standardError.write(Data("window check failed: \(error)\n".utf8))
            status = 1
        }
        // A leftover temporary store is reclaimed by the system; it must not change the exit status.
        do { try FileManager.default.removeItem(at: store) } catch {}
        exit(status)
    }

    private static func check(_ team: TeamModel, selected name: String) async throws {
        let hosting = NSHostingView(rootView: WindowSnapshots.Root(team: team, isInspectorRequested: true))
        // The scene's window resizes freely above its minimum; the default would follow the ideal size.
        hosting.sizingOptions = [.minSize]
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 612),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(NSSize(width: 900, height: 612))
        window.makeKeyAndOrderFront(nil)
        print("window check \(name): shown at \(window.frame.size)")
        try await Task.sleep(for: .seconds(3))

        for width in widths {
            window.setContentSize(NSSize(width: width, height: 612))
            try await Task.sleep(for: .milliseconds(600))
            print("window check \(name): asked \(Int(width)), now \(window.frame.size)")
        }
        try await Task.sleep(for: .seconds(2))
        window.close()
    }
}

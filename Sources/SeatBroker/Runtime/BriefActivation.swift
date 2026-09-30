//
//  BriefActivation.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AppKit
import os
import SeatCore
import SeatInput

/// BriefActivation brings the driven application in front for a moment and gives the front back
/// to the person's window, for an application that recomputes its interface only when it becomes
/// active.
///
/// Measured on 30/09/2026 with Photoshop, which only the seat had driven since it was launched:
/// its whole File and Layer menus read disabled with a document open, a press on a disabled item
/// did nothing, and neither did the key-window records. Brought in front by the person, it
/// re-enabled them, and they stayed enabled once it was behind again. It is the one place the
/// seat takes the front on purpose, chosen per application (Adobe's UXP applications) and only
/// when a menu item reads disabled; the front goes back through the focus recovery's own
/// restorer, whatever happens in between.
@MainActor
enum BriefActivation {

    /// How long the application is in front: long enough for it to recompute its menus.
    // ponytail: one value, not measured below it; the person's own click held it for seconds.
    static let hold: Duration = .milliseconds(150)

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Lab")

    /// Brings the focused window of `processID` in front for `hold`, then the person's focused
    /// window. False when nothing was done: no person's window to come back to, the application
    /// already in front, or the restorer not qualified on this build.
    static func refresh(processID: pid_t, allowUnvalidatedBuild: Bool) async -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != processID,
              let person = LaunchFocusComeback.focusedWindow(of: front),
              let target = LaunchFocusComeback.focusedWindow(of: processID),
              let restorer = try? UserFocusRestorer(allowUnvalidatedBuild: allowUnvalidatedBuild),
              (try? restorer.prepare(target, targets: [])) != nil
        else { return false }

        let code = (try? restorer.restore(target)) ?? -1
        if code == 0 { try? await Task.sleep(for: hold) }
        // The front goes back in every case: a request that failed may still have taken it.
        if (try? restorer.prepare(person, targets: [])) != nil { _ = try? restorer.restore(person) }
        log.info("""
            brought pid \(processID, privacy: .public) in front for its menus, request code \
            \(code, privacy: .public), and gave the front back to window \(person.windowNumber, privacy: .public)
            """)
        return code == 0
    }
}

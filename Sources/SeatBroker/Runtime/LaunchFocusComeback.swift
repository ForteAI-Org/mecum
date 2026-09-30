//
//  LaunchFocusComeback.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AppKit
import ApplicationServices
import os
import SeatCore
import SeatInput
import WindowPlacement

/// LaunchFocusComeback is the person's own window, prepared before a launch as the way back to it.
///
/// An application can make itself active as it starts, whatever the launch asked for, and no seat
/// exists yet to give the front back: the seat's focus recovery prepares its way back while the
/// person's application is in front, and by then the launched one is. Measured with DaVinci
/// Resolve on 30/09/2026: active from 1.7 s to 24.6 s of a background launch, adopted active, and
/// the seat waited until the person clicked elsewhere. The front goes back through the recovery's
/// own restorer, and only while the launched application holds it: an application the person
/// chose meanwhile is left in front.
///
/// A running browser given a new window takes the front the same way, during or just after that
/// window's adoption and before the seat knows a window of the person's (measured with Chrome on
/// 30/09/2026, 2 of 2), so `BrowserOpening.seat` arms one before its press.
@MainActor
final class LaunchFocusComeback: FrontRestoring {

    /// The front is given back this many times at most: an application that keeps taking it is
    /// the seat's focus recovery's to answer once it is adopted.
    static let restoreLimit = 3

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Lab")

    private let restorer: UserFocusRestorer
    private let window  : WindowReference
    private let taker   : String
    private var restores = 0

    /// Nil when there is no person's window in front to come back to, or the restorer is not
    /// qualified on this build: the launch then goes on as it did before. `taker` names the
    /// application watched in the log line.
    init?(allowUnvalidatedBuild: Bool, taker: String = "the launched application") {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = Self.focusedWindow(of: front),
              let restorer = try? UserFocusRestorer(allowUnvalidatedBuild: allowUnvalidatedBuild),
              (try? restorer.prepare(window, targets: [])) != nil
        else { return nil }
        self.restorer = restorer
        self.window   = window
        self.taker    = taker
    }

    /// Whether the application of the person's window is the frontmost one now.
    var isPersonsApplicationInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == window.processID
    }

    /// Gives the front back when `pid`, the application being launched, has taken it.
    func restore(ifTakenBy pid: pid_t) {
        guard restores < Self.restoreLimit,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return }
        restores += 1
        do {
            let code = try restorer.restore(window)
            Self.log.info("""
                \(self.taker, privacy: .public) \(pid, privacy: .public) took the front: sent it back to \
                window \(self.window.windowNumber, privacy: .public), request code \(code, privacy: .public)
                """)
            try restorer.prepare(window, targets: [])
        } catch {
            Self.log.info("""
                \(self.taker, privacy: .public) \(pid, privacy: .public) took the front and it could not be \
                given back: \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// The focused window of `pid` as the window server attests it, or nil.
    static func focusedWindow(of pid: pid_t) -> WindowReference? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
              let number = WindowRelocator.windowNumber(of: unsafeDowncast(value, to: AXUIElement.self)),
              let window = WindowServerProbe.geometry(of: number), window.processID == pid
        else { return nil }
        return window
    }
}

/// FrontRestoring gives the front back to the person's window when an application the seat is
/// taking has taken it, and says whether the person's application holds it now.
@MainActor
protocol FrontRestoring: AnyObject {

    /// Gives the front back when `pid` holds it, a bounded number of times.
    func restore(ifTakenBy pid: pid_t)

    var isPersonsApplicationInFront: Bool { get }
}

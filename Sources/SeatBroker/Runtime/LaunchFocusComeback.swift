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
    private let allowUnvalidatedBuild: Bool
    private var restores = 0

    /// Nil when there is no person's window in front to come back to, or the restorer is not
    /// qualified on this build: the launch then goes on as it did before. `taker` names the
    /// application watched in the log line.
    init?(allowUnvalidatedBuild: Bool, taker: String = "the launched application") {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            Self.log.notice("no way back to the person's window: no frontmost application")
            return nil
        }
        guard let window = Self.focusedWindow(of: front) else {
            Self.log.notice("""
                no way back to the person's window: process \(front, privacy: .public) has no \
                attested focused window
                """)
            return nil
        }
        let restorer: UserFocusRestorer
        do {
            restorer = try UserFocusRestorer(allowUnvalidatedBuild: allowUnvalidatedBuild)
            try restorer.prepare(window, targets: [])
        } catch {
            Self.log.notice("""
                no way back to the person's window \(window.windowNumber, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return nil
        }
        self.restorer = restorer
        self.window   = window
        self.taker    = taker
        self.allowUnvalidatedBuild = allowUnvalidatedBuild
    }

    /// Brings the focused window of `pid` in front on purpose, through a restorer of its own so
    /// the way back prepared in `init` stays whole, and answers whether that process held the
    /// front within `bound`. The hand back is `restore(ifTakenBy:)`, which the caller owns.
    ///
    /// For an application whose new window item opens nothing from the background (Safari,
    /// ADR 0038). The request is the one the seat's brief activation makes, key window included;
    /// no seat exists yet, so nothing else is told to expect it. It refuses, answering false and
    /// logging why, when the application has no attested focused window or the request fails.
    func bringInFront(processID pid: pid_t, atMost bound: Duration = .seconds(1)) async -> Bool {
        guard let target = Self.focusedWindow(of: pid) else {
            Self.log.notice("""
                \(self.taker, privacy: .public) \(pid, privacy: .public) has no attested focused \
                window to bring forward
                """)
            return false
        }
        do {
            let bringer = try UserFocusRestorer(allowUnvalidatedBuild: allowUnvalidatedBuild)
            try bringer.prepare(target, targets: [])
            let code = try bringer.restore(target, primesKeyWindow: true)
            guard code == 0 else {
                Self.log.notice("""
                    the request to bring \(self.taker, privacy: .public) \(pid, privacy: .public) \
                    forward was refused with code \(code, privacy: .public)
                    """)
                return false
            }
        } catch {
            Self.log.notice("""
                \(self.taker, privacy: .public) \(pid, privacy: .public) could not be brought \
                forward: \(String(describing: error), privacy: .public)
                """)
            return false
        }
        let deadline = ContinuousClock.now + bound
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            guard ContinuousClock.now < deadline else {
                Self.log.notice("\(self.taker, privacy: .public) \(pid, privacy: .public) did not take the front within the bound")
                return false
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        Self.log.notice("\(self.taker, privacy: .public) \(pid, privacy: .public) was brought forward on purpose")
        return true
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
            Self.log.notice("""
                \(self.taker, privacy: .public) \(pid, privacy: .public) took the front: sent it back to \
                window \(self.window.windowNumber, privacy: .public), request code \(code, privacy: .public)
                """)
            try restorer.prepare(window, targets: [])
        } catch {
            Self.log.notice("""
                \(self.taker, privacy: .public) \(pid, privacy: .public) took the front and it could not be \
                given back: \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// The focused window of `pid` as the window server attests it, or nil. An application that
    /// answers `cannotComplete` inside the 0.1 s timeout is asked once more: the first request
    /// from a new accessibility client can take longer (Claude's own Electron window, measured
    /// on 09/10/2026), and a second one answers at once.
    static func focusedWindow(of pid: pid_t) -> WindowReference? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var value: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        if error == .cannotComplete {
            error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
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

//
//  BrowserOpening.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import ApplicationServices
import AutomationRuntime
import CoreGraphics
import Foundation
import os
import WindowPlacement

/// BrowserOpening gives a web browser the person already has running a window of its own for the
/// seat, so that `AgentSession.open` never works in one of the person's windows of it. While the
/// seat holds the browser, ADR 0010 still takes its other visible windows onto the seat's display.
///
/// A browser's windows are where the person is signed in, reading or in a call: adopting the main
/// one moved the window a call was running in to the background display. A browser is any
/// application registered for https (`WebBrowsers.bundleIDs`). The window comes from the browser's
/// own new window item, which `MenuBarCommand.newWindowItem` finds by its key equivalent in any
/// language, and it is the one window adopted: when it does not appear, `open` refuses and never
/// falls back to a window the browser already had.
///
/// Measured on 30/09/2026 on macOS 27, both browsers behind the person's application: pressing the
/// item left the front application unchanged, sampled every 10 ms. Chrome's File > New Window was
/// listed by the window server 28 ms after the press. Safari with profiles has no Command-N; its
/// New Personal Window appeared after about a second, Stage Manager showed it at once as a
/// thumbnail in its strip, and about a second later Safari's `AXWindows` was empty while the window
/// server still listed both its windows.
///
/// The first live run, the same day, pressed that item and then failed to start the background
/// display, which another process held: the new empty window stayed on the person's display for
/// good, since by then nothing in accessibility listed it to close. Hence `seat`'s order.
enum BrowserOpening {

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Lab")

    /// A window this open made, with its accessibility element read while `AXWindows` still listed
    /// it: once Stage Manager takes the window off stage, nothing in accessibility finds it again.
    /// `element` is nil when accessibility named no window with this Window ID in time.
    struct OpenedWindow {
        let window : TargetWindow
        let element: AXUIElement?
    }

    /// How long a pressed item is given to show its window: Safari took about 1 s, Chrome 28 ms.
    static let windowTimeout: Duration = .seconds(3)

    /// How many times the front is read after the adoption, one `tailInterval` apart: about a
    /// second, since Chrome took the front during or just after it (30/09/2026, 2 of 2).
    static let frontTailReadings = 20

    /// Whether `open` gives the application a new window instead of adopting one it has: only a
    /// browser that was already running, and only with no window named. A title names the one
    /// window to take, which the worker passes only when the person asks for it, and a browser
    /// this open launches has no window of the person's to protect.
    static func opensNewWindow(wasRunning: Bool, windowTitled title: String?, isBrowser: Bool) -> Bool {
        wasRunning && title == nil && isBrowser
    }

    /// Makes the seat ready, opens a window of `app` and seats it, in that order, and answers what
    /// `use` answered. Nothing is pressed before `prepare` succeeds, so a seat that cannot come up
    /// costs the person nothing. When `use` fails, the window `open` made is closed again with
    /// `close`, and the refusal says whether it was; no other window is ever closed. A window that
    /// was seated stays open here: the session closes it when it finishes with the browser.
    ///
    /// The browser can take the front during or just after the adoption, while the seat knows no
    /// window of the person's to give it back to. So `arm` reads the person's window after
    /// `prepare` and before the press, `open` calls its `tick` on every reading of its wait, and
    /// after `use`, seated or not, the front is given back for up to `frontTailReadings`, ending
    /// early once the person's application holds it for two readings in a row. With nothing armed
    /// the flow is the same without any of it.
    @MainActor
    static func seat(
        _ app       : TargetApp,
        prepare     : () async throws -> Void,
        arm         : () -> (any FrontRestoring)?,
        open        : (_ tick: () -> Void) async throws -> OpenedWindow,
        use         : (OpenedWindow) async throws -> TargetApp,
        close       : (OpenedWindow) async -> Bool,
        tailInterval: Duration = .milliseconds(50)
    ) async throws -> TargetApp {

        do {
            try await prepare()
        } catch {
            if error is CancellationError { throw error }
            throw refusal(app.name, "The seat could not be made ready, so nothing was pressed: "
                + SeatErrorMapper.message(for: error))
        }
        let comeback = arm()
        let giveFrontBack = { if let comeback, let pid = app.pid { comeback.restore(ifTakenBy: pid) } }
        let opened = try await open(giveFrontBack)
        let seated: TargetApp
        do {
            seated = try await use(opened)
        } catch {
            let closing = await close(opened)
                ? "The new window it opened for the seat was closed again."
                : "A new empty window of \(app.name) was left open on the person's screen: close it by hand."
            await holdFront(comeback, giveBack: giveFrontBack, interval: tailInterval)
            throw SeatBrokerError.driver(ApplicationOpening.notSeated(app, cause: error).localizedDescription
                + " " + closing)
        }
        await holdFront(comeback, giveBack: giveFrontBack, interval: tailInterval)
        return seated
    }

    /// Gives the front back after the adoption until the person's application has held it for two
    /// readings in a row, `frontTailReadings` at most. A cancellation ends it: the adoption is over.
    @MainActor
    private static func holdFront(
        _ comeback: (any FrontRestoring)?,
        giveBack  : () -> Void,
        interval  : Duration
    ) async {
        guard let comeback else { return }
        var inFront = 0
        for _ in 0..<frontTailReadings {
            giveBack()
            inFront = comeback.isPersonsApplicationInFront ? inFront + 1 : 0
            if inFront == 2 { return }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// The first of `shown` that is none of the windows listed `before` the press, or nil.
    static func newWindow(among shown: [TargetWindow], before: Set<Int>) -> TargetWindow? {
        shown.first { !before.contains($0.windowNumber) }
    }

    /// Presses the new window item of `app`, a running browser, and answers the window it opened as
    /// `TargetEnumerator` lists it: on screen, at the normal layer and not tiny. The windows the
    /// browser had before the press are read from the whole window server list, on screen or not,
    /// so one of the person's that Stage Manager brings on screen meanwhile is never taken for it.
    /// Once the window is listed, its accessibility element is looked for by Window ID until
    /// `timeout`, and the window is answered with or without it. `tick` runs before every reading.
    ///
    /// Throws `SeatBrokerError.driver` when there is no such item, the press fails or no new window
    /// appears within `timeout`, having adopted nothing and released nothing. A window that appears
    /// after the timeout stays open on the person's display.
    @MainActor
    static func openWindow(
        of app        : TargetApp,
        within timeout: Duration = windowTimeout,
        tick          : () -> Void
    ) async throws -> OpenedWindow {

        guard let pid = app.pid else { throw refusal(app.name, "It is not running.") }
        let before  = windowNumbers(of: pid)
        let pressed: String
        do {
            pressed = try MenuBarCommand.pressNewWindow(processID: pid)
        } catch {
            throw refusal(app.name, "\(error)")
        }
        let started = ContinuousClock.now
        let opened  = try await awaitWindow(
            within : timeout,
            tick   : tick,
            find   : { newWindow(among: TargetEnumerator.windows(of: pid), before: before) },
            element: { element(ofWindow: $0.windowNumber, of: pid) }
        )
        guard let opened else {
            throw refusal(app.name, "\(pressed) was pressed and no new window of it appeared within "
                + "\(timeout.components.seconds) s; if one opens later, it stays on the person's screen.")
        }
        let waited = started.duration(to: .now).components
        let milliseconds = waited.seconds * 1000 + waited.attoseconds / 1_000_000_000_000_000
        log.notice("""
            \(app.name, privacy: .public) was running: pressed \(pressed, privacy: .public) and adopting \
            its new window \(opened.window.windowNumber, privacy: .public), listed after \
            \(milliseconds, privacy: .public) ms, accessibility element found: \
            \(opened.element != nil, privacy: .public)
            """)
        return opened
    }

    /// Reads `find` until it answers a window and `element` answers that window's element, or
    /// `timeout` passes, running `tick` before every reading. The window found first is kept, and
    /// it is answered without its element when the time runs out; nil when none was found.
    @MainActor
    static func awaitWindow(
        within timeout: Duration,
        interval      : Duration = .milliseconds(50),
        tick          : () -> Void,
        find          : () -> TargetWindow?,
        element       : (TargetWindow) -> AXUIElement?
    ) async throws -> OpenedWindow? {

        let started = ContinuousClock.now
        var found: TargetWindow?
        while true {
            tick()
            found = found ?? find()
            if let found, let resolved = element(found) { return OpenedWindow(window: found, element: resolved) }
            guard started.duration(to: .now) < timeout else { break }
            try await Task.sleep(for: interval)
        }
        return found.map { OpenedWindow(window: $0, element: nil) }
    }

    /// Presses the close button of `opened` and answers whether the window is gone within a second
    /// (20 readings, 50 ms apart), by `isClosed`. The element is the one read by Window ID when the
    /// window appeared, so no other window can be closed; with no element, or no close button to
    /// press, nothing is done. Nothing is pressed or typed twice, and an unreadable element or
    /// window list counts as still there.
    @MainActor
    static func close(_ opened: OpenedWindow) async -> Bool {
        var button: CFTypeRef?
        guard let element = opened.element,
              AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(unsafeDowncast(button, to: AXUIElement.self), kAXPressAction as CFString)
                == .success
        else { return false }
        for _ in 0..<20 {
            if isGone(opened.window, element: element) { return true }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        return isGone(opened.window, element: element)
    }

    /// Whether a window the person was shown is closed, from four readings taken after the press.
    /// An application may keep a closed window in the window server, off screen, so being listed
    /// is not enough to say it is open: accessibility must also no longer have it, since a
    /// minimized window is off screen too and stays in `AXWindows`. A window on screen never is.
    static func isClosed(listed: Bool, onScreen: Bool, elementIsValid: Bool, inWindows: Bool) -> Bool {
        !listed || (!onScreen && (!elementIsValid || !inWindows))
    }

    /// Takes the four readings for `isClosed`, reading accessibility only for a window that the
    /// window server lists off screen.
    private static func isGone(_ window: TargetWindow, element: AXUIElement) -> Bool {
        guard let row = description(of: window) else {
            return isClosed(listed: false, onScreen: false, elementIsValid: true, inWindows: true)
        }
        if row[kCGWindowIsOnscreen as String] as? Bool ?? false { return false }

        AXUIElementSetMessagingTimeout(element, 0.5)
        var role: CFTypeRef?
        let elementIsValid = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            != .invalidUIElement
        let application = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var windows: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
        let inWindows = read != .success || ((windows as? [AXUIElement]) ?? []).contains { CFEqual($0, element) }
        return isClosed(listed: true, onScreen: false, elementIsValid: elementIsValid, inWindows: inWindows)
    }

    /// The refusal for a browser that got no window of its own, in a sentence the worker can act on.
    static func refusal(_ name: String, _ reason: String) -> SeatBrokerError {
        .driver("\(name) could not be given a window of its own: \(reason) Nothing was adopted and none of "
            + "the person's \(name) windows was taken. Tell the person; name one of their windows with "
            + "open_session's window only if they ask you to use it.")
    }

    /// The accessibility window of `pid` whose Window ID is `number`, from `AXWindows` or else the
    /// main window; nil when neither is that window. Never matched by title or frame.
    @MainActor
    private static func element(ofWindow number: Int, of pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var listed: CFTypeRef?
        var main  : CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &listed)
        AXUIElementCopyAttributeValue(application, kAXMainWindowAttribute as CFString, &main)
        let candidates = ((listed as? [AXUIElement]) ?? [])
            + [main].compactMap { $0 }.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                .map { unsafeDowncast($0, to: AXUIElement.self) }
        return candidates.first { WindowRelocator.windowNumber(of: $0) == number }
    }

    /// The window server's row for `window` alone, nil when it no longer lists that Window ID for
    /// that process. The ID crosses as a raw `CFArray` value, the shape
    /// `CGWindowListCreateDescriptionFromArray` reads, not as a `CFNumber`.
    private static func description(of window: TargetWindow) -> [String: Any]? {
        var values = [UnsafeRawPointer(bitPattern: UInt(window.windowNumber))]
        guard let requested = values.withUnsafeMutableBufferPointer({
            CFArrayCreate(kCFAllocatorDefault, $0.baseAddress, $0.count, nil)
        }) else { return nil }
        let rows = CGWindowListCreateDescriptionFromArray(requested) as? [[String: Any]] ?? []
        return rows.first {
            $0[kCGWindowNumber as String] as? Int == window.windowNumber
                && $0[kCGWindowOwnerPID as String] as? pid_t == window.pid
        }
    }

    /// Every window the window server has for `pid`, on screen or not.
    private static func windowNumbers(of pid: pid_t) -> Set<Int> {
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(rows.compactMap { row in
            row[kCGWindowOwnerPID as String] as? pid_t == pid ? row[kCGWindowNumber as String] as? Int : nil
        })
    }
}

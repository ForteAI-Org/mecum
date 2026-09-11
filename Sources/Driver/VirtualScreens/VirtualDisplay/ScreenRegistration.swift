//
//  ScreenRegistration.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics

/// ScreenRegistration is the AppKit half of a virtual display's life: the point
/// where `NSScreen` admits the display exists. It is the only place in
/// `VirtualScreens` that touches AppKit.
///
/// The distinction it exists to make is a measured one.
/// `applySettings:` publishes the display to CoreGraphics in a few hundred
/// milliseconds, but `CGConfigureDisplayOrigin` only accepts it into the
/// topology once **AppKit** has registered it, another 21 to 61 ms later, and
/// AppKit refreshes `NSScreen.screens` from the application event loop. A
/// process that waits with `RunLoop.run` alone never sees the display appear;
/// it has to pump real events. That is why the wait is written as a predicate
/// plus a thin `async` wrapper: a consumer with a live `NSApplication` awaits
/// the wrapper, and a test process drives the predicate from its own
/// `nextEvent` loop.
public enum ScreenRegistration {

    /// The `NSScreen` AppKit publishes for a display id, or `nil` while it has
    /// not published one.
    public static func screen(for wanted: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == wanted }
    }

    /// The display id behind an `NSScreen`, or `nil` for a screen whose device
    /// description does not carry one.
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// The screen that contains a rectangle's centre, falling back to the main
    /// screen. It answers "which display is this window on", which is a
    /// question about the centre and not about the corners: a window straddling
    /// two displays belongs to the one showing most of it.
    public static func screen(containing frame: CGRect) -> NSScreen? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main
    }

    /// The display, other than `excluding`, whose bounds contain `point`, or
    /// `nil` when the point falls on none of them.
    ///
    /// It answers a different question from `frameReachesPhysicalDisplay`, and
    /// the difference is the whole reason it exists. "Is this window on one of
    /// the person's displays" is a question about **one point**, and a point
    /// either falls inside a display or it does not: there is no minimum
    /// overlap to meet. Feeding a point sized rectangle to the reach predicate
    /// cannot answer it, because that one asks for tens of points of overlap
    /// and a one point rectangle never reaches them, so it answers `false` for
    /// every window on every display.
    ///
    /// The pure form takes the displays as an argument so the decision is
    /// testable without a machine; the wrapper below reads the online list.
    nonisolated public static func display(
        containing point: CGPoint,
        among displays: [PhysicalDisplay],
        excluding: CGDirectDisplayID? = nil
    ) -> CGDirectDisplayID? {
        displays.first { $0.displayID != excluding && $0.bounds.contains(point) }?.displayID
    }

    /// The online display, other than `excluding`, whose bounds contain
    /// `point`. Membership in `CGGetOnlineDisplayList` for the reason written
    /// on `DisplayList`: a display that vanished still answers "online" to the
    /// wrong idiom.
    public static func onlineDisplay(
        containing point: CGPoint,
        excluding: CGDirectDisplayID?
    ) throws -> CGDirectDisplayID? {
        let displays = try DisplayList.online().map {
            PhysicalDisplay(displayID: $0, bounds: CGDisplayBounds($0))
        }
        return display(containing: point, among: displays, excluding: excluding)
    }

    /// Whether `frame` reaches a display that is **not** the given one and is
    /// still in `CGGetOnlineDisplayList`, by at least `minimumWidth` by
    /// `minimumHeight` points.
    ///
    /// It is written as list membership and not as `CGDisplayIsOnline` even
    /// though these ids come from `NSScreen` and therefore exist: the wrong
    /// idiom reads as "online" for a display that vanished, and leaving one
    /// copy of it in the codebase is how it comes back. See `DisplayList`.
    public static func frameReachesPhysicalDisplay(
        _ frame      : CGRect,
        excluding    : CGDirectDisplayID?,
        minimumWidth : CGFloat = 40,
        minimumHeight: CGFloat = 12
    ) throws -> Bool {

        let online = Set(try DisplayList.online())
        return NSScreen.screens.contains { screen in
            guard let id = displayID(of: screen), online.contains(id), id != excluding
            else { return false }
            let intersection = frame.intersection(screen.frame)
            return intersection.width >= minimumWidth && intersection.height >= minimumHeight
        }
    }

    /// Waits for AppKit to publish the display, for a consumer that has a live
    /// application event loop. Without one this returns `nil` after `timeout`
    /// no matter how long the timeout is, which is not a bug in the wait: see
    /// the type's own documentation.
    public static func waitForScreen(
        displayID: CGDirectDisplayID,
        timeout  : TimeInterval = 5,
        interval : Duration     = .milliseconds(20)
    ) async -> NSScreen? {

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let screen = screen(for: displayID) { return screen }
            do { try await Task.sleep(for: interval) } catch { return screen(for: displayID) }
        }
        return screen(for: displayID)
    }
}

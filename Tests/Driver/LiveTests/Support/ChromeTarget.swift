//
//  ChromeTarget.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import WindowPlacement

/// ChromeWindow is one window of another application, as the window server
/// describes it. The matrix needs the owner, the id, the frame and the title,
/// and the title is the only channel a web page has to report what happened to
/// a process outside the browser.
nonisolated struct ChromeWindow {

    let processID   : pid_t
    let windowNumber: Int
    let frame       : CGRect
    let title       : String

    /// Every window of an application, by its owner name. `kCGWindowName` is
    /// only readable with the Screen Recording grant, so the title may come
    /// back empty and the caller falls back to accessibility.
    static func windows(ownedBy ownerName: String) -> [ChromeWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        else {
            return []
        }
        return entries.compactMap { entry in
            guard (entry[kCGWindowOwnerName as String] as? String) == ownerName,
                  let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
            else {
                return nil
            }
            return ChromeWindow(
                processID   : processID,
                windowNumber: number,
                frame       : frame,
                title       : entry[kCGWindowName as String] as? String ?? ""
            )
        }
    }

    /// The accessibility element of one window of another application, found
    /// through the kit's own `_AXUIElementGetWindow` bridge. It is the only way
    /// to ask a **stashed** window what it really is: Stage Manager shows the
    /// window server a thumbnail, while the application still describes itself
    /// at full size.
    static func element(processID: pid_t, windowNumber: Int) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  application,
                  kAXWindowsAttribute as CFString,
                  &value
              ) == .success,
              let windows = value as? [AXUIElement]
        else {
            return nil
        }
        return windows.first { WindowRelocator.windowNumber(of: $0) == windowNumber }
    }

    /// The window's title through accessibility, for when the window server
    /// will not hand it over.
    static func accessibilityTitle(processID: pid_t, windowNumber: Int) -> String {
        guard let window = element(processID: processID, windowNumber: windowNumber) else {
            return ""
        }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  window,
                  kAXTitleAttribute as CFString,
                  &titleValue
              ) == .success
        else {
            return ""
        }
        return titleValue as? String ?? ""
    }

    /// The frame the application itself believes the window has, which is the
    /// full size even while Stage Manager is showing a thumbnail of it.
    static func accessibilityFrame(processID: pid_t, windowNumber: Int) -> CGRect? {
        guard let window = element(processID: processID, windowNumber: windowNumber) else {
            return nil
        }
        guard let position = axValue(of: window, kAXPositionAttribute, .cgPoint),
              let measured = axValue(of: window, kAXSizeAttribute,     .cgSize)
        else {
            return nil
        }
        var origin = CGPoint.zero
        var size   = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(measured, .cgSize,  &size)
        else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// One `AXValue` attribute of the requested kind. The type is checked with
    /// the runtime's own id before the cast, because `CFTypeRef as? AXValue`
    /// always succeeds in Swift: the same guard the kit's relocator uses.
    private static func axValue(
        of element: AXUIElement,
        _ name    : String,
        _ type    : AXValueType
    ) -> AXValue? {

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }

        let boxed = unsafeDowncast(raw, to: AXValue.self)
        return AXValueGetType(boxed) == type ? boxed : nil
    }
}

/// ChromeTarget is the Chromium half of the matrix: a local page whose script
/// counts clicks, keys, wheel deltas and the distance of a drag, and publishes
/// them in the window title, which is the one thing another process can read
/// without asking the browser for anything.
///
/// Nothing about the page is privileged. It is a plain file opened in the
/// person's own browser, and the driver reaches it the same way it would reach
/// any other renderer.
@MainActor
final class ChromeTarget: MatrixTarget {

    static let ownerName  = "Google Chrome"
    static let titleMark  = "AS c="

    let name     = "Chrome page"
    let platform: any InputPlatform

    let processID   : pid_t
    let windowNumber: Int

    /// The frame the window had before it was moved onto the Virtual Display,
    /// so the person gets their window back where they left it.
    let originalFrame: CGRect

    private var frame: CGRect

    init(
        window  : ChromeWindow,
        platform: any InputPlatform = ChromiumPlatform()
    ) {
        self.platform = platform
        processID    = window.processID
        windowNumber = window.windowNumber
        frame        = window.frame
        // The window server's frame is a thumbnail when Stage Manager has
        // stashed the window, and a thumbnail is neither where the person left
        // it nor what "full size" means for the staging check. The
        // application's own answer is.
        originalFrame = ChromeWindow.accessibilityFrame(
            processID   : window.processID,
            windowNumber: window.windowNumber
        ) ?? window.frame
    }

    /// Finds the probe page among the browser's windows. The title is read from
    /// the window server first and from accessibility second, because a window
    /// that was just opened, or that Stage Manager has stashed, often has no
    /// readable name.
    static func find() -> ChromeTarget? {
        let candidates = ChromeWindow.windows(ownedBy: ownerName)
        if let named = candidates
            .filter({ $0.title.contains(titleMark) })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return ChromeTarget(window: named)
        }
        for candidate in candidates {
            let title = ChromeWindow.accessibilityTitle(
                processID   : candidate.processID,
                windowNumber: candidate.windowNumber
            )
            guard title.contains(titleMark) else { continue }
            return ChromeTarget(window: candidate)
        }
        return nil
    }

    /// Every probe page window the browser owns, largest first.
    ///
    /// `find` answers the biggest one, which is what a single target row wants.
    /// The two window rows want both, because the question they ask is whether
    /// two windows of **one process** share what the kit is holding down: the
    /// PID is the boundary the system has, and the registry is keyed by it on
    /// that belief.
    static func findAll() -> [ChromeTarget] {
        let candidates = ChromeWindow.windows(ownedBy: ownerName)
        let named = candidates.filter { $0.title.contains(titleMark) }
        let byAccessibility = candidates.filter { candidate in
            !candidate.title.contains(titleMark)
                && ChromeWindow.accessibilityTitle(
                    processID   : candidate.processID,
                    windowNumber: candidate.windowNumber
                ).contains(titleMark)
        }
        return (named + byAccessibility)
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .map { ChromeTarget(window: $0) }
    }

    var window: WindowReference {
        guard let reference = WindowServerProbe.geometry(of: windowNumber),
              reference.processID == processID
        else {
            return WindowReference(processID: processID, windowNumber: windowNumber, frame: frame)
        }
        return reference.replacingFrame(frame)
    }

    var family: TargetFamily { .chromium }

    var expectedSize: CGSize { originalFrame.size }

    /// A browser gives no honest answer to this from outside: `isActive` on
    /// another process disagrees with the frontmost application, and the page
    /// cannot see its own AppKit state. Reported as false and covered by the
    /// frontmost checks instead.
    var isInternallyActive: Bool { false }

    var diagnostics: String { "title '\(title())' frame \(frame)" }

    func refresh() {
        guard let geometry = WindowServerProbe.geometry(of: windowNumber) else { return }
        frame = geometry.frame
    }

    /// The mark every counter title starts with. A title without it is not a
    /// reading at all, and the difference matters: this window's title through
    /// accessibility is the single word "Chrome", which parses into a full set
    /// of missing counters that look exactly like numbers. One row then fails
    /// because nothing ever moved, and its neighbour passes because a counter
    /// went from a real value to a missing one, which is worse.
    static let counterMark = "AS c="

    /// The counters, or an empty string. The window server publishes them in
    /// the window's title and accessibility does not, so the fallback is kept
    /// for a build where that changes and is held to the same test. The wait is
    /// on the condition rather than the clock: a title read in the instant the
    /// page is rewriting it comes back empty.
    func title() -> String {
        let deadline = Date().addingTimeInterval(0.6)
        repeat {
            if let entry = ChromeWindow.windows(ownedBy: Self.ownerName)
                .first(where: { $0.windowNumber == windowNumber }) {
                frame = entry.frame
                if entry.title.contains(Self.counterMark) { return entry.title }
            }
            let spoken = ChromeWindow.accessibilityTitle(
                processID   : processID,
                windowNumber: windowNumber
            )
            if spoken.contains(Self.counterMark) { return spoken }
            usleep(30_000)
        } while Date() < deadline
        return ""
    }

    /// Decodes the probe's compact counter packet into the fixture's field names.
    func state() -> [String: Double] {
        Self.parseState(title())
    }

    /// Rejects truncated or partial counter packets instead of inventing zeros.
    static func parseState(_ published: String) -> [String: Double] {
        guard let marker = published.range(of: counterMark) else { return [:] }
        let payload = published[marker.upperBound...].split(separator: " ").first ?? ""
        let fields = payload.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 12 else { return [:] }
        let names = [0: "clicks", 1: "keys", 2: "wheel", 3: "drag", 4: "typed",
                     5: "paste", 6: "field", 9: "shortcutEffects", 10: "lastModifiers",
                     11: "dialogOpen"]
        var result: [String: Double] = [:]
        for (index, name) in names {
            guard let number = Double(fields[index]), number.isFinite else { return [:] }
            result[name] = number
        }
        for (index, name) in [7: "shortcutDelivered", 8: "shortcutEffect"] {
            let code = String(fields[index])
            guard code == "--" || ShortcutRow.allCases.contains(where: { $0.code == code })
            else { return [:] }
            result[name] = ShortcutRow.number(ofCode: code)
        }
        result["chars"] = result["typed"]! + result["paste"]!
        result["keyDowns"] = result["keys"]
        return result
    }

    /// The page is one full-window button, so the middle of the content area is
    /// on the control whatever the browser's chrome is doing above it.
    func clickPoint() -> CGPoint? {
        refresh()
        return CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.62)
    }

    func scrollPoint() -> CGPoint? { clickPoint() }

    func dragEndpoints() -> (start: CGPoint, end: CGPoint)? {
        guard let base = clickPoint() else { return nil }
        return (CGPoint(x: base.x - 120, y: base.y), CGPoint(x: base.x + 120, y: base.y))
    }
}

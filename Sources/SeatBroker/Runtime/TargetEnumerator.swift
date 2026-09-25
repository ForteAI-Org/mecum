import AppKit
import ApplicationServices
import CoreGraphics
import SeatCore
import WindowPlacement

/// Installed applications merged with the running ones and their on-screen,
/// normal-layer windows. The seat driver attests a window later; this only
/// lists candidates.
enum TargetEnumerator {
    private static let applicationFolders = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    @MainActor
    static func targets(minimumSize: CGFloat = 120) -> [TargetApp] {
        let windowsByPID = onScreenWindows(minimumSize: minimumSize)
        let me = ProcessInfo.processInfo.processIdentifier
        var byPath: [String: TargetApp] = [:]

        for url in installedApplicationURLs() {
            guard let bundle = Bundle(url: url) else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            byPath[url.path] = TargetApp(pid: nil, bundleID: bundle.bundleIdentifier ?? "", name: name,
                                         bundleURL: url, windows: [])
        }
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            let windows = windowsByPID[app.processIdentifier] ?? []
            guard listable(app.activationPolicy, hasWindows: !windows.isEmpty) else { continue }
            // A process with no Dock presence is listed for as long as its
            // window is up and is gone with it, so it carries no bundle: it
            // exists because a host asked for it and nothing can launch it.
            let launchable = app.activationPolicy == .regular ? app.bundleURL : nil
            let key = launchable?.path ?? "pid:\(app.processIdentifier)"
            byPath[key] = TargetApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
                                    name: app.localizedName ?? byPath[key]?.name ?? "?",
                                    bundleURL: launchable, windows: windows)
        }
        return byPath.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether a running process is offered as a target.
    ///
    /// An ordinary application always is, window or not: it can be launched
    /// and then adopted. A process the Dock never shows is not an application
    /// and is not offered — unless it is drawing a normal window right now,
    /// which is measured and not assumed. The open and save panel service is
    /// the case that asks for this: it draws the panel's own window for the
    /// application that asked for one, under its own process, and that window
    /// is the only thing the seat can adopt to reach the panel. `.accessory`
    /// stays out because a menu bar item with an overlay is not a target the
    /// person meant; `.prohibited` with a window on screen is one.
    static func listable(_ policy: NSApplication.ActivationPolicy, hasWindows: Bool) -> Bool {
        switch policy {
        case .regular   : return true
        case .prohibited: return hasWindows
        default         : return false
        }
    }

    /// The windows a process currently has on screen.
    static func windows(of pid: pid_t, minimumSize: CGFloat = 120) -> [TargetWindow] {
        onScreenWindows(minimumSize: minimumSize)[pid] ?? []
    }

    // MARK: Which window of an application is the one to work in

    /// One listed window and what accessibility says about it.
    ///
    /// Every field but the window is optional because every reading behind it
    /// is: an application that publishes no accessibility windows answers none
    /// of them, and a window that is missing a reading is not thereby a dialog.
    struct WindowCandidate: Sendable, Equatable {
        let window: TargetWindow

        /// `AXSubrole`, which is what separates a standard window from a sheet.
        let subrole: String?

        /// `AXMain`: the one window of the application that is its main one.
        let isMain: Bool?

        /// The window this one hangs off, when accessibility names another
        /// window as its parent. Nil for a window whose parent is the
        /// application itself, which is the ordinary case.
        let parentWindowNumber: Int?
    }

    /// The subroles that say a window is attached to another one rather than
    /// being the application's own.
    static let attachedSubroles: Set<String> = ["AXSheet", "AXDialog", "AXFloatingWindow"]

    /// Which of an application's listed windows the seat should work in.
    ///
    /// The list this chooses from is every on-screen layer-zero window above
    /// the minimum size, and taking the first of them is what put the seat in
    /// Slack's "Open" sheet: measured on 18/09/2026, window 45152 at 933×490,
    /// adopted while the application's own window sat behind it. A sheet is a
    /// window by every measure the window server has, so the separation has to
    /// come from accessibility, and it is made twice over: by subrole, and by
    /// the window naming another window as its parent, which is what a sheet
    /// does and a standard window does not.
    ///
    /// Then the main window, because that is the application's own answer to
    /// this exact question, and the largest of what is left when it gives
    /// none: an application that publishes no accessibility windows at all
    /// leaves every field nil, and size is then the only evidence there is.
    ///
    /// The fallback of last resort is the largest window of the whole list,
    /// exclusions included. An application whose only on-screen window is a
    /// sheet still has to be adoptable, and refusing there would be a seat that
    /// can open nothing rather than a seat in the wrong window.
    static func mainWindow(among candidates: [WindowCandidate]) -> TargetWindow? {
        let standalone = candidates.filter {
            $0.parentWindowNumber == nil && !attachedSubroles.contains($0.subrole ?? "")
        }
        let pool = standalone.isEmpty ? candidates : standalone
        if let main = pool.first(where: { $0.isMain == true && $0.subrole == "AXStandardWindow" }) {
            return main.window
        }
        if let main = pool.first(where: { $0.isMain == true }) { return main.window }
        // Largest first, ties by window number so the same list always
        // answers the same window.
        return pool.sorted {
            let (left, right) = (area(of: $0.window), area(of: $1.window))
            return left == right
                ? $0.window.windowNumber < $1.window.windowNumber
                : left > right
        }.first?.window
    }

    private static func area(of window: TargetWindow) -> CGFloat {
        window.frame.width * window.frame.height
    }

    /// The windows of `pid` that accessibility names, which are the only ones the seat can move.
    @MainActor
    static func accessibleWindowNumbers(of pid: pid_t) -> Set<Int> {
        Set(accessibilityReadings(of: pid).keys)
    }

    /// The shown windows the seat can take: the ones accessibility names. A splash screen is shown
    /// and named by nobody.
    static func adoptable(_ shown: [TargetWindow], named: Set<Int>) -> [TargetWindow] {
        shown.filter { named.contains($0.windowNumber) }
    }

    /// The application's listed windows with the accessibility reading of each
    /// one folded in, and the windows alone when nothing can be read.
    @MainActor
    static func candidates(of app: TargetApp) -> [WindowCandidate] {
        let readings = app.pid.map(accessibilityReadings) ?? [:]
        return app.windows.map { window in
            let reading = readings[window.windowNumber]
            return WindowCandidate(window: window, subrole: reading?.subrole,
                                   isMain: reading?.isMain,
                                   parentWindowNumber: reading?.parentWindowNumber)
        }
    }

    /// Subrole, main and parent for every accessibility window of one process
    /// that resolves to a Window ID.
    ///
    /// `WindowRelocator.windowNumber` is the bridge between the two identities
    /// and the kit's own, gated where the private symbol is gated. A window the
    /// bridge cannot name is left out rather than guessed at by title or frame.
    @MainActor
    private static func accessibilityReadings(
        of pid: pid_t
    ) -> [Int: (subrole: String?, isMain: Bool?, parentWindowNumber: Int?)] {
        let application = AXUIElementCreateApplication(pid)
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement]
        else { return [:] }
        var readings: [Int: (subrole: String?, isMain: Bool?, parentWindowNumber: Int?)] = [:]
        for element in windows {
            guard let number = WindowRelocator.windowNumber(of: element) else { continue }
            readings[number] = (
                subrole: attribute(element, kAXSubroleAttribute) as? String,
                isMain : (attribute(element, kAXMainAttribute) as? NSNumber)?.boolValue,
                parentWindowNumber: windowElement(attribute(element, kAXParentAttribute))
                    .flatMap { WindowRelocator.windowNumber(of: $0) }
            )
        }
        return readings
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// An attribute value as an accessibility element. The type is checked
    /// rather than cast, because `AXUIElement` is a CoreFoundation type and a
    /// conditional cast from `CFTypeRef` does not check anything.
    private static func windowElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func installedApplicationURLs() -> [URL] {
        applicationURLs(in: applicationFolders)
    }

    /// The applications in `folders`: the ones standing there, and the ones one folder down, where
    /// a suite installs itself ("DaVinci Resolve/DaVinci Resolve.app") and macOS keeps its
    /// Utilities. An application's own bundle is never looked into.
    static func applicationURLs(in folders: [URL]) -> [URL] {
        func entries(of folder: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
        }
        return folders.flatMap { entries(of: $0) }.flatMap { entry in
            entry.pathExtension == "app" ? [entry] : entries(of: entry).filter { $0.pathExtension == "app" }
        }
    }

    private static func onScreenWindows(minimumSize: CGFloat) -> [pid_t: [TargetWindow]] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return onScreenWindows(
            in: list,
            minimumSize: minimumSize,
            resolveNativeFrame: nativeFrame
        )
    }

    /// Stage Manager can publish a small on-screen thumbnail for a full-size
    /// application window. Keep the ordinary WindowServer-only path cheap,
    /// and consult Accessibility only for a layer-zero row below the minimum.
    static func onScreenWindows(
        in list: [[String: Any]],
        minimumSize: CGFloat,
        resolveNativeFrame: (pid_t, Int) -> CGRect?
    ) -> [pid_t: [TargetWindow]] {
        var windowsByPID: [pid_t: [TargetWindow]] = [:]
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? Int,
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }

            let frame: CGRect
            if bounds.width >= minimumSize, bounds.height >= minimumSize {
                frame = bounds
            } else {
                guard let nativeFrame = resolveNativeFrame(pid, number),
                      usableNativeBody(nativeFrame, minimumSize: minimumSize)
                else { continue }
                frame = nativeFrame
            }

            let title = info[kCGWindowName as String] as? String ?? ""
            windowsByPID[pid, default: []].append(
                TargetWindow(pid: pid, windowNumber: number, title: title, frame: frame))
        }
        return windowsByPID
    }

    private static func nativeFrame(of processID: pid_t, windowNumber: Int) -> CGRect? {
        resolvedNativeFrame(
            processID: processID,
            windowNumber: windowNumber,
            reference: WindowServerProbe.geometry(of: windowNumber),
            readFrame: { try WindowRelocator.frame(of: $0) }
        )
    }

    /// The WindowServer witness binds a reusable window number to one process
    /// lifetime before the AX body is read. The seam keeps that ordering under
    /// focused tests without replacing either production witness.
    static func resolvedNativeFrame(
        processID: pid_t,
        windowNumber: Int,
        reference: WindowReference?,
        readFrame: (WindowReference) throws -> CGRect?
    ) -> CGRect? {
        guard let reference,
              reference.identity != nil,
              reference.processID == processID,
              reference.windowNumber == windowNumber
        else { return nil }
        return try? readFrame(reference)
    }

    private static func usableNativeBody(_ frame: CGRect, minimumSize: CGFloat) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
            && frame.width >= minimumSize && frame.height >= minimumSize
    }
}

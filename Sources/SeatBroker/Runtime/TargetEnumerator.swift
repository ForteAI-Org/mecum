import AppKit
import ApplicationServices
import CoreGraphics
import CoreServices
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
        var pathByBundleID: [String: String] = [:]

        for app in installedApplications() {
            byPath[app.id] = app
            pathByBundleID[app.bundleID] = app.id
        }
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            let windows = windowsByPID[app.processIdentifier] ?? []
            guard listable(app.activationPolicy, hasWindows: !windows.isEmpty) else { continue }
            // A process with no Dock presence is listed for as long as its
            // window is up and is gone with it, so it carries no bundle: it
            // exists because a host asked for it and nothing can launch it.
            let launchable = app.activationPolicy == .regular ? app.bundleURL : nil
            let key = launchable?.path ?? "pid:\(app.processIdentifier)"
            // The running copy stands in for the installed one of its bundle ID wherever each sits:
            // Safari runs from its cryptex while Spotlight lists /Applications/Safari.app.
            let sibling   = launchable == nil ? nil : app.bundleIdentifier.flatMap { pathByBundleID[$0] }
            let installed = sibling.flatMap { byPath.removeValue(forKey: $0) }
                ?? launchable.flatMap { application(at: $0, row: nil) }
            byPath[key] = TargetApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
                                    name: app.localizedName ?? installed?.name ?? "?",
                                    bundleURL: launchable, windows: windows, bundleName: installed?.bundleName,
                                    version: installed?.version, lastUsed: installed?.lastUsed)
        }
        return byPath.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Which applications are installed

    /// One application bundle found on disk, before its bundle is read.
    struct InstalledRow: Equatable {
        let path       : String
        let bundleID   : String?
        let displayName: String?
        let lastUsed   : Date?
    }

    // ponytail: the installed list is kept 5 s, so apps then open_session asks Spotlight once;
    // an application installed meanwhile is found when it expires.
    private static let installedLifetime: Duration = .seconds(5)

    @MainActor
    private static var installedCache: (taken: ContinuousClock.Instant, apps: [TargetApp])?

    /// Every installed application, from Spotlight, or from the folder scan when Spotlight finds
    /// none or fails, as with indexing off. Read again once the cached list is `installedLifetime` old.
    @MainActor
    private static func installedApplications() -> [TargetApp] {
        if let installedCache, ContinuousClock.now - installedCache.taken < installedLifetime {
            return installedCache.apps
        }
        let rows = spotlightRows() ?? applicationURLs(in: applicationFolders).map { url in
            InstalledRow(path: url.path, bundleID: Bundle(url: url)?.bundleIdentifier, displayName: nil,
                         lastUsed: nil)
        }
        let kept = installable(rows) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        let apps = kept.compactMap { application(at: URL(fileURLWithPath: $0.path), row: $0) }
        installedCache = (ContinuousClock.now, apps)
        return apps
    }

    /// The application at `url`, not running, named as its bundle names it. A system agent is none:
    /// see `isSystemAgent`.
    private static func application(at url: URL, row: InstalledRow?) -> TargetApp? {
        guard let bundle = Bundle(url: url),
              !isSystemAgent(path: url.path, info: bundle.infoDictionary ?? [:]) else { return nil }
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? bundleName
            ?? row?.displayName
            ?? url.deletingPathExtension().lastPathComponent
        return TargetApp(pid: nil, bundleID: bundle.bundleIdentifier ?? "", name: name, bundleURL: url,
                         windows: [], bundleName: bundleName,
                         version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                         lastUsed: row?.lastUsed)
    }

    /// The rows that are applications a person opens, one per bundle identifier.
    ///
    /// A bundle inside another bundle is left out: Xcode's Instruments or Finder's own helpers are
    /// parts of that application, not applications of their own. So is the Trash, whose contents
    /// the person threw away. So is `/System/Library` outside `CoreServices`: the rest of it is
    /// frameworks' helpers, input methods and services, while `CoreServices` holds Finder and the
    /// system's own applications. So is a bundle with no identifier: `open_session` is told to
    /// open by one, and the ones Spotlight found here were test fixtures named "Xcode". When one
    /// identifier sits at several paths, the one Launch Services names (`preferred`) is kept, then
    /// one under `/Applications`, then the first by path.
    static func installable(_ rows: [InstalledRow], preferred: (String) -> String?) -> [InstalledRow] {
        func isApplication(_ path: String) -> Bool {
            let components = path.split(separator: "/")
            return !components.dropLast().contains { $0.hasSuffix(".app") }
                && !components.contains { $0 == ".Trash" || $0 == ".Trashes" }
                && (!path.hasPrefix("/System/Library/") || path.hasPrefix("/System/Library/CoreServices/"))
        }
        func rank(_ row: InstalledRow, _ bundleID: String) -> Int {
            row.path == preferred(bundleID) ? 0 : row.path.hasPrefix("/Applications/") ? 1 : 2
        }
        var kept: [String: InstalledRow] = [:]
        for row in rows.sorted(by: { $0.path < $1.path }) where isApplication(row.path) {
            guard let bundleID = row.bundleID, !bundleID.isEmpty else { continue }
            if let held = kept[bundleID], rank(held, bundleID) <= rank(row, bundleID) { continue }
            kept[bundleID] = row
        }
        return kept.values.sorted { $0.path < $1.path }
    }

    /// Whether the bundle at `path` is one of `CoreServices`' agents: a helper with no Dock presence
    /// (`LSUIElement` or `LSBackgroundOnly`), which Finder is not. They borrow real applications'
    /// names: PeopleViewService shows as "Contacts", GameTrampoline as "Games", TipsSpotlightHandler
    /// as "Tips", so kept they made "open Contacts" ambiguous while Contacts was not running. A
    /// running agent is left out the same way (`listable`).
    static func isSystemAgent(path: String, info: [String: Any]) -> Bool {
        func isOn(_ key: String) -> Bool {
            switch info[key] {
            case let flag as Bool:   flag
            case let text as String: ["1", "yes", "true"].contains(text.lowercased())
            default:                 false
            }
        }
        return path.hasPrefix("/System/Library/CoreServices/") && (isOn("LSUIElement") || isOn("LSBackgroundOnly"))
    }

    /// Every application bundle Spotlight has indexed, or nil when the query fails or finds none.
    ///
    /// The query runs synchronously, so no run loop is needed. The path is read from each item,
    /// and the other attributes from the query's own value lists, which is what keeps it fast:
    /// copying them item by item took 260 ms for 376 bundles here, against 4 ms this way.
    private static func spotlightRows() -> [InstalledRow]? {
        let attributes = [kMDItemCFBundleIdentifier, kMDItemDisplayName, kMDItemLastUsedDate] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault,
                                        "kMDItemContentType == \"com.apple.application-bundle\"" as CFString,
                                        attributes, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        else { return nil }
        func value(_ name: CFString, at index: Int) -> Any? {
            MDQueryGetAttributeValueOfResultAtIndex(query, name, index)
                .map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        }
        let rows = (0..<MDQueryGetResultCount(query)).compactMap { index -> InstalledRow? in
            guard let result = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(result).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
            return InstalledRow(path: path, bundleID: value(kMDItemCFBundleIdentifier, at: index) as? String,
                                displayName: value(kMDItemDisplayName, at: index) as? String,
                                lastUsed: value(kMDItemLastUsedDate, at: index) as? Date)
        }
        return rows.isEmpty ? nil : rows
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

    /// The windows a process currently has on screen, or, when it has none,
    /// the ones it keeps in native fullscreen on a Space that is not on screen.
    @MainActor
    static func windows(of pid: pid_t, minimumSize: CGFloat = 120) -> [TargetWindow] {
        windows(
            of            : pid,
            onScreen      : onScreenWindows(minimumSize: minimumSize)[pid] ?? [],
            readFullScreen: { fullScreenReadings(of: pid) },
            readRows      : { numbers in
                numbers.flatMap { number in
                    CGWindowID(exactly: number).flatMap {
                        CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]]
                    } ?? []
                }
            }
        )
    }

    /// The windows `launch` hands on for one process: its on-screen ones, and
    /// when it has none, every window accessibility says is in native
    /// fullscreen, as the window server lists it.
    ///
    /// A fullscreen window whose Space is not the one on screen is not on
    /// screen either, so the on-screen list leaves it out: Safari with its only
    /// window fullscreen on its own Space, measured on 29/09/2026, read as
    /// running with no window, was asked to reopen one and was refused 20 s
    /// later for a window it had all along. The evidence has to be positive:
    /// `AXFullScreen` true on one of the application's accessibility windows.
    /// False or unreadable is no window: a row the server lists and nothing
    /// shows is not evidence of a window the seat can take. The rectangle and
    /// title come from the server's row of that window number and owner, and
    /// the adoption attests its identity anyway.
    ///
    /// The readings are closures so that the cost stays where it belongs: an
    /// application with a window on screen reads no accessibility at all, and
    /// one with no fullscreen window reads no server row.
    static func windows(
        of pid        : pid_t,
        onScreen      : [TargetWindow],
        readFullScreen: () -> [Int: Bool],
        readRows      : ([Int]) -> [[String: Any]]
    ) -> [TargetWindow] {
        guard onScreen.isEmpty else { return onScreen }
        let fullScreen = readFullScreen().filter(\.value).keys.sorted()
        guard !fullScreen.isEmpty else { return [] }
        return readRows(fullScreen).compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let number = info[kCGWindowNumber as String] as? Int,
                  fullScreen.contains(number),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  !bounds.isEmpty
            else { return nil }
            return TargetWindow(
                pid         : pid,
                windowNumber: number,
                title       : info[kCGWindowName as String] as? String ?? "",
                frame       : bounds
            )
        }
    }

    /// `AXFullScreen` for every accessibility window of `pid` that resolves to
    /// a Window ID, leaving out the ones that do not answer it.
    ///
    /// `AXWindows` answers an empty list while the only window sits in a
    /// fullscreen Space off screen, measured by the kit on 26A428, so the
    /// application's focused and main windows are read as well, which are the
    /// same two routes `WindowRelocator` resolves such a window through.
    @MainActor
    private static func fullScreenReadings(of pid: pid_t) -> [Int: Bool] {
        let application = AXUIElementCreateApplication(pid)
        let listed      = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let named       = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].compactMap {
            windowElement(attribute(application, $0))
        }
        var readings: [Int: Bool] = [:]
        for element in listed + named {
            guard let number = WindowRelocator.windowNumber(of: element),
                  let isFullScreen = attribute(element, "AXFullScreen") as? NSNumber
            else { continue }
            readings[number] = isFullScreen.boolValue
        }
        return readings
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

    /// The applications in `folders`: the ones standing there, and the ones up to `depth` folders
    /// down, where a suite installs itself ("DaVinci Resolve/DaVinci Resolve.app", or a vendor's
    /// folder holding a suite's) and macOS keeps its Utilities. An application's own bundle is never
    /// looked into. This is the fallback for when Spotlight finds nothing.
    static func applicationURLs(in folders: [URL], depth: Int = 2) -> [URL] {
        folders.flatMap { folder in
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles])) ?? []
            return entries.flatMap { entry in
                entry.pathExtension == "app" ? [entry] : depth > 0 ? applicationURLs(in: [entry], depth: depth - 1) : []
            }
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

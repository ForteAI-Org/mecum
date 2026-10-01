import AppKit
import CoreGraphics
import SeatCore
import Testing
@testable import SeatBroker

private func windowInfo(
    pid: pid_t = 42,
    number: Int = 7,
    layer: Int = 0,
    frame: CGRect
) -> [String: Any] {
    [
        kCGWindowOwnerPID as String: pid,
        kCGWindowNumber as String: number,
        kCGWindowLayer as String: layer,
        kCGWindowBounds as String: frame.dictionaryRepresentation,
        kCGWindowName as String: "Project Manager",
    ]
}

@Test func elevatedDialogRequiresAnAttestedNativeWindow() throws {
    let frame = CGRect(x: 10, y: 20, width: 1_069, height: 694)
    let row = windowInfo(layer: 8, frame: frame)
    var readings = 0
    let windows = TargetEnumerator.onScreenWindows(in: [row], minimumSize: 120) { pid, number in
        #expect(pid == 42 && number == 7)
        readings += 1
        return frame
    }
    #expect(windows[42]?.first?.windowNumber == 7)
    #expect(readings == 1)
    let unqualified = TargetEnumerator.onScreenWindows(in: [row], minimumSize: 120) { _, _ in nil }
    #expect(unqualified.isEmpty)
}

@Test func ordinaryWindowDoesNotResolveANativeFrame() throws {
    var resolutionCount = 0
    let serverFrame = CGRect(x: 10, y: 20, width: 800, height: 600)

    let windows = TargetEnumerator.onScreenWindows(
        in: [windowInfo(frame: serverFrame)],
        minimumSize: 120
    ) { _, _ in
        resolutionCount += 1
        return CGRect(x: 0, y: 0, width: 900, height: 700)
    }

    let window = try #require(windows[42]?.first)
    #expect(window.frame == serverFrame)
    #expect(resolutionCount == 0)
}

@Test func stageManagerThumbnailUsesItsQualifiedNativeBody() throws {
    let thumbnail = CGRect(x: 0, y: 0, width: 121, height: 117)
    let body = CGRect(x: 40, y: 60, width: 1_134, height: 640)

    let windows = TargetEnumerator.onScreenWindows(
        in: [windowInfo(frame: thumbnail)],
        minimumSize: 120
    ) { pid, number in
        #expect(pid == 42)
        #expect(number == 7)
        return body
    }

    #expect(try #require(windows[42]?.first).frame == body)
}

@Test func subminimumWindowNeedsAUsableNativeBody() {
    let thumbnail = CGRect(x: 0, y: 0, width: 121, height: 117)
    let invalidBodies: [CGRect?] = [
        nil,
        CGRect(x: 0, y: 0, width: 119, height: 640),
        CGRect(x: CGFloat.infinity, y: 0, width: 1_134, height: 640),
    ]

    for body in invalidBodies {
        let windows = TargetEnumerator.onScreenWindows(
            in: [windowInfo(frame: thumbnail)],
            minimumSize: 120,
            resolveNativeFrame: { _, _ in body }
        )
        #expect(windows.isEmpty)
    }
}

@Test func nonApplicationLayerNeverResolvesANativeFrame() {
    var resolutionCount = 0
    let windows = TargetEnumerator.onScreenWindows(
        in: [windowInfo(layer: 25, frame: CGRect(x: 0, y: 0, width: 121, height: 117))],
        minimumSize: 120
    ) { _, _ in
        resolutionCount += 1
        return CGRect(x: 0, y: 0, width: 1_134, height: 640)
    }

    #expect(windows.isEmpty)
    #expect(resolutionCount == 0)
}

@Test func nativeFrameRequiresAnAttestedMatchingReference() {
    let process = ProcessIdentity(processID: 42, serialNumberHigh: 1, serialNumberLow: 2)
    let identity = WindowIdentity(process: process, windowNumber: 7, ownerConnectionID: 3)
    let attested = WindowReference(
        identity: identity,
        frame: CGRect(x: 0, y: 0, width: 121, height: 117)
    )
    let body = CGRect(x: 40, y: 60, width: 1_134, height: 640)
    var readCount = 0
    let read: (WindowReference) throws -> CGRect? = { _ in
        readCount += 1
        return body
    }

    #expect(TargetEnumerator.resolvedNativeFrame(
        processID: 42, windowNumber: 7, reference: attested, readFrame: read
    ) == body)
    #expect(TargetEnumerator.resolvedNativeFrame(
        processID: 43, windowNumber: 7, reference: attested, readFrame: read
    ) == nil)
    #expect(TargetEnumerator.resolvedNativeFrame(
        processID: 42, windowNumber: 8, reference: attested, readFrame: read
    ) == nil)
    #expect(TargetEnumerator.resolvedNativeFrame(
        processID: 42,
        windowNumber: 7,
        reference: WindowReference(processID: 42, windowNumber: 7, frame: .zero),
        readFrame: read
    ) == nil)
    #expect(readCount == 1)
}

@Test("A process with no Dock presence is a target only while it has a window")
func listableProcesses() {
    #expect(TargetEnumerator.listable(.regular, hasWindows: false))
    #expect(TargetEnumerator.listable(.prohibited, hasWindows: true))
    #expect(!TargetEnumerator.listable(.prohibited, hasWindows: false))
    #expect(!TargetEnumerator.listable(.accessory, hasWindows: true))
}

// MARK: Which window of an application is the one to work in

private func candidate(
    _ number: Int,
    _ frame: CGRect,
    subrole: String? = "AXStandardWindow",
    isMain: Bool? = false,
    parent: Int? = nil
) -> TargetEnumerator.WindowCandidate {
    TargetEnumerator.WindowCandidate(
        window: TargetWindow(pid: 42, windowNumber: number, title: "w\(number)", frame: frame),
        subrole: subrole,
        isMain: isMain,
        parentWindowNumber: parent
    )
}

@Test("The sheet that was adopted at 14:41 is not the window the seat works in")
func aSheetIsNotTheApplicationsWindow() {
    // Today's run: window 45152 at 933x490 is Slack's "Open" panel, listed
    // first and taken because it was first.
    let sheet = candidate(45_152, CGRect(x: 200, y: 100, width: 933, height: 490),
                          subrole: "AXSheet", parent: 45_100)
    let own = candidate(45_100, CGRect(x: 0, y: 0, width: 1_440, height: 900), isMain: true)
    #expect(TargetEnumerator.mainWindow(among: [sheet, own])?.windowNumber == 45_100)
}

@Test("A subrole that says attached is excluded even with no parent to prove it")
func attachedSubrolesAreExcluded() {
    let big = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
    let small = CGRect(x: 0, y: 0, width: 400, height: 300)
    for subrole in ["AXSheet", "AXDialog", "AXFloatingWindow"] {
        let attached = candidate(1, big, subrole: subrole)
        let own = candidate(2, small)
        #expect(TargetEnumerator.mainWindow(among: [attached, own])?.windowNumber == 2)
    }
}

@Test("A window whose parent is another window of the same application is excluded")
func aChildWindowIsExcluded() {
    // The subrole alone does not always say it: the parent does.
    let child = candidate(1, CGRect(x: 0, y: 0, width: 1_600, height: 1_000), parent: 2)
    let own = candidate(2, CGRect(x: 0, y: 0, width: 400, height: 300))
    #expect(TargetEnumerator.mainWindow(among: [child, own])?.windowNumber == 2)
}

@Test("The main standard window wins over a larger one that is not main")
func theMainWindowIsTheApplicationsOwnAnswer() {
    let main = candidate(1, CGRect(x: 0, y: 0, width: 800, height: 600), isMain: true)
    let larger = candidate(2, CGRect(x: 0, y: 0, width: 1_600, height: 1_000))
    #expect(TargetEnumerator.mainWindow(among: [larger, main])?.windowNumber == 1)
}

@Test("With nothing read at all the largest window is the only evidence there is")
func theLargestWindowIsTheFallback() {
    // An application that publishes no accessibility windows leaves every
    // field nil, which is not the same as saying its windows are dialogs.
    let small = candidate(1, CGRect(x: 0, y: 0, width: 400, height: 300),
                          subrole: nil, isMain: nil)
    let large = candidate(2, CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
                          subrole: nil, isMain: nil)
    #expect(TargetEnumerator.mainWindow(among: [small, large])?.windowNumber == 2)

    // Equal areas are decided by window number so the same list always
    // answers the same window.
    let first = candidate(9, CGRect(x: 0, y: 0, width: 500, height: 500), subrole: nil, isMain: nil)
    let second = candidate(4, CGRect(x: 0, y: 0, width: 500, height: 500), subrole: nil, isMain: nil)
    #expect(TargetEnumerator.mainWindow(among: [first, second])?.windowNumber == 4)
}

@Test("An application whose only window is a sheet is still adoptable")
func theExclusionNeverLeavesNothing() {
    let sheet = candidate(1, CGRect(x: 0, y: 0, width: 933, height: 490),
                          subrole: "AXSheet", parent: 2)
    #expect(TargetEnumerator.mainWindow(among: [sheet])?.windowNumber == 1)
    #expect(TargetEnumerator.mainWindow(among: []) == nil)
}

@Test func anApplicationTwoFoldersDownIsInstalledAndOneInsideABundleOrDeeperIsNot() throws {
    let root  = URL.temporaryDirectory.appending(path: "applications-\(UUID().uuidString)")
    let files = FileManager.default
    defer { try? files.removeItem(at: root) }
    for path in [
        "Notes.app/Contents",
        "DaVinci Resolve/DaVinci Resolve.app/Contents",
        "Utilities/Terminal.app/Contents",
        "Xcode.app/Contents/Applications/Instruments.app",
        "Suite/Tools/Deep.app",
        "Vendor/Suite/Tools/Deeper.app",
    ] {
        try files.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
    }

    let names = TargetEnumerator.applicationURLs(in: [root]).map(\.lastPathComponent).sorted()
    #expect(names == ["DaVinci Resolve.app", "Deep.app", "Notes.app", "Terminal.app", "Xcode.app"])
}

private func row(_ path: String, _ bundleID: String?) -> TargetEnumerator.InstalledRow {
    TargetEnumerator.InstalledRow(path: path, bundleID: bundleID, displayName: nil, lastUsed: nil)
}

@Test func spotlightRowsKeepOneOpenableBundlePerIdentifier() {
    let rows = [
        row("/Applications/Xcode.app", "com.apple.dt.Xcode"),
        row("/Applications/Xcode.app/Contents/Applications/Instruments.app", "com.apple.dt.Instruments"),
        row("/Users/me/.Trash/Old.app", "com.example.Old"),
        row("/System/Library/Input Methods/CharacterPalette.app", "com.apple.CharacterPaletteIM"),
        row("/System/Library/CoreServices/Finder.app", "com.apple.finder"),
        row("/Users/me/Library/DerivedData/Build/Mecum.app", "dev.forte.Mecum"),
        row("/Applications/Mecum.app", "dev.forte.Mecum"),
        row("/Users/me/Downloads/Mecum.app", "dev.forte.Mecum"),
        row("/Users/me/Projects/build/Output/Xcode.app", nil),
    ]
    let kept = TargetEnumerator.installable(rows) { _ in nil }.map(\.path)
    #expect(kept == ["/Applications/Mecum.app", "/Applications/Xcode.app", "/System/Library/CoreServices/Finder.app"])

    // The copy Launch Services names wins over the one under /Applications.
    let named = TargetEnumerator.installable(rows) {
        $0 == "dev.forte.Mecum" ? "/Users/me/Library/DerivedData/Build/Mecum.app" : nil
    }
    #expect(named.filter { $0.bundleID == "dev.forte.Mecum" }.map(\.path)
        == ["/Users/me/Library/DerivedData/Build/Mecum.app"])
}

@Test func aSplashScreenNobodyNamesIsNotAWindowToAdopt() {
    let splash  = TargetWindow(pid: 42, windowNumber: 39136, title: "", frame: CGRect(x: 0, y: 0, width: 700, height: 400))
    let manager = TargetWindow(pid: 42, windowNumber: 39468, title: "Project Manager",
                               frame: CGRect(x: 0, y: 0, width: 910, height: 640))
    #expect(TargetEnumerator.adoptable([splash], named: []).isEmpty)
    #expect(TargetEnumerator.adoptable([splash, manager], named: [39468]) == [manager])
}

@Test func aCoreServicesAgentIsNotAnApplicationToOpenButFinderIs() {
    // PeopleViewService calls itself "Contacts" and made "open Contacts" ambiguous while Contacts was closed.
    #expect(TargetEnumerator.isSystemAgent(path: "/System/Library/CoreServices/PeopleViewService.app",
                                           info: ["LSUIElement": true]))
    #expect(TargetEnumerator.isSystemAgent(path: "/System/Library/CoreServices/GameTrampoline.app",
                                           info: ["LSBackgroundOnly": "1"]))
    #expect(!TargetEnumerator.isSystemAgent(path: "/System/Library/CoreServices/Finder.app", info: [:]))
    // A menu bar application a person installed is not the system's, and stays listed.
    #expect(!TargetEnumerator.isSystemAgent(path: "/Applications/Raycast.app", info: ["LSUIElement": true]))
}

// MARK: A window in native fullscreen on a Space that is not on screen

@Test("A fullscreen window on a Space off screen is found through accessibility")
func aFullScreenWindowOffScreenIsFound() {
    // The 29/09 run: Safari's only window was fullscreen on its own Space
    // while the person was on the desktop, so nothing of it was on screen.
    let body = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    var askedFor: [Int] = []
    let windows = TargetEnumerator.windows(
        of            : 42,
        onScreen      : [],
        readFullScreen: { [9: true, 8: false] },
        readRows      : { numbers in
            askedFor = numbers
            return [windowInfo(number: 9, frame: body),
                    windowInfo(pid: 43, number: 9, frame: body)]
        }
    )
    #expect(askedFor == [9])
    #expect(windows == [TargetWindow(pid: 42, windowNumber: 9, title: "Project Manager", frame: body)])
}

@Test("An application with no window on screen and none in fullscreen still has none")
func noFullScreenWindowIsStillNoWindow() {
    var rowReads = 0
    let windows = TargetEnumerator.windows(
        of            : 42,
        onScreen      : [],
        readFullScreen: { [8: false] },
        readRows      : { _ in
            rowReads += 1
            return [windowInfo(number: 8, frame: CGRect(x: 0, y: 0, width: 800, height: 600))]
        }
    )
    #expect(windows.isEmpty)
    #expect(rowReads == 0)

    // A row with no usable rectangle is no window either.
    let degenerate = TargetEnumerator.windows(
        of            : 42,
        onScreen      : [],
        readFullScreen: { [9: true] },
        readRows      : { _ in [windowInfo(number: 9, frame: .zero)] }
    )
    #expect(degenerate.isEmpty)
}

@Test("An application with a window on screen is listed as before and reads no accessibility")
func anOnScreenApplicationIsUnchanged() {
    let shown = TargetWindow(pid: 42, windowNumber: 7, title: "w7",
                             frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    var reads = 0
    let windows = TargetEnumerator.windows(
        of            : 42,
        onScreen      : [shown],
        readFullScreen: { reads += 1; return [9: true] },
        readRows      : { _ in reads += 1; return [] }
    )
    #expect(windows == [shown])
    #expect(reads == 0)
}

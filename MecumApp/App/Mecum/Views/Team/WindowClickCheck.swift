//
//  WindowClickCheck.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Observation
import SwiftUI
import TeamShell
import Workspace

/// WindowClickCheck puts the team shell in a real key window, when the app is
/// launched with MECUM_CLICK_CHECK=1, and drives the window's chrome with
/// events sent through the window: a click on the worker header, Space on it
/// once it has focus, and a click on the sidebar's Connections footer. It
/// prints what each step found and quits with 0 when every step held, 1 otherwise.
///
/// SwiftUI builds no accessibility tree without an assistive client, so the
/// targets are found by geometry: the header at the top centre of the
/// conversation's safe area, the footer at the bottom of the sidebar's. The
/// events go to the window, so the pointer never moves. The team is
/// `WindowSnapshots`'s synthetic one, in a temporary store.
@MainActor
enum WindowClickCheck {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["MECUM_CLICK_CHECK"] == "1" }

    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// The window's inspector request, readable from outside the shell.
    @Observable
    final class Probe {
        var isInspectorRequested = false
    }

    struct ProbedRoot: View {
        let team : TeamModel
        let probe: Probe

        var body: some View {
            TeamShellView(team: team, isInspectorRequested: Binding(
                get: { probe.isInspectorRequested },
                set: { probe.isInspectorRequested = $0 }
            ))
        }
    }

    static func runAndQuit() async {
        let store = URL.temporaryDirectory.appending(path: "MecumClickCheck-\(UUID().uuidString)",
                                                     directoryHint: .isDirectory)
        var status: Int32 = 0
        do {
            try await run(team: WindowSnapshots.syntheticTeam(in: store))
            print("click check: every step held")
        } catch {
            FileHandle.standardError.write(Data("click check failed: \(error)\n".utf8))
            status = 1
        }
        // A leftover temporary store is reclaimed by the system; it must not change the exit status.
        do { try FileManager.default.removeItem(at: store) } catch {}
        exit(status)
    }

    private static func run(team: TeamModel) async throws {
        let probe   = Probe()
        let hosting = NSHostingView(rootView: ProbedRoot(team: team, probe: probe))
        hosting.sizingOptions = [.minSize]
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1200, height: 720),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(3))
        if !window.isKeyWindow {
            // Launched from a shell, the app may not be allowed to take the front on its own.
            NSRunningApplication.current.activate(options: .activateAllWindows)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(2))
        }
        print("click check: app active \(NSApp.isActive), key \(window.isKeyWindow), frame \(window.frame)")

        print("click check: window title \"\(window.title)\", title visibility \(window.titleVisibility.rawValue)")
        let items = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        print("click check: toolbar items \(items)")
        try expect(window.title == "Atlas", "the window title is \(window.title)")

        let panes = try splitPanes(in: hosting)
        print("click check: panes \(panes.map { window.contentView?.convert($0.bounds, from: $0) ?? .zero })")
        try expect(!probe.isInspectorRequested && !showsInspector(hosting), "the inspector is shown before the click")

        // The mascot, at the leading edge of the title bar above the conversation's safe area.
        let header = point(in: panes[1], fromTop: -26, leading: 22, in: window)
        // A window that is not key spends a click on becoming key, as on a Mac someone is using.
        if !window.isKeyWindow { click(at: header, in: window) }
        click(at: header, in: window)
        try await Task.sleep(for: .seconds(1))
        print("click check: after the header click, requested \(probe.isInspectorRequested)")
        try expect(probe.isInspectorRequested && showsInspector(hosting),
                   "clicking the header did not show the inspector")

        // Close it with its shortcut, then Space on the header, which the click should have focused.
        press("i", keyCode: 34, modifiers: [.control, .option, .command], in: window, throughApp: true)
        try await Task.sleep(for: .seconds(1))
        print("click check: after Control-Option-Command-I, requested \(probe.isInspectorRequested)")
        try expect(!probe.isInspectorRequested && !showsInspector(hosting),
                   "Control-Option-Command-I did not hide the inspector")
        print("click check: first responder \(String(describing: window.firstResponder.map { type(of: $0) }))")
        press(" ", keyCode: 49, modifiers: [], in: window, throughApp: false)
        try await Task.sleep(for: .seconds(1))
        print("click check: after Space, requested \(probe.isInspectorRequested)")
        try expect(probe.isInspectorRequested && showsInspector(hosting),
                   "Space on the focused header did not show the inspector")

        let footer = point(in: panes[0], fromBottom: 20, leading: 60, in: window)
        click(at: footer, in: window)
        try await Task.sleep(for: .seconds(1))
        print("click check: after the footer click, showing \(team.isShowingConnections), "
            + "sheet \(window.attachedSheet != nil)")
        try expect(team.isShowingConnections && window.attachedSheet != nil,
                   "clicking Connections did not open the sheet")
        team.isShowingConnections = false
        try await Task.sleep(for: .seconds(1))

        team.selection = nil
        try await Task.sleep(for: .seconds(1))
        print("click check: no worker selected, window title \"\(window.title)\"")
        try expect(window.title == ShellChrome.untitled, "the window title stayed \(window.title)")
        window.close()
    }

    // MARK: Geometry

    /// The shown panes of the outermost split view: the sidebar, the conversation and, when shown, the inspector.
    private static func splitPanes(in root: NSView) throws -> [NSView] {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let split = view as? NSSplitView {
                return split.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 1 }
            }
            queue += view.subviews
        }
        throw CheckFailure(description: "no split view in the window")
    }

    /// The widths of every split view's shown panes, outermost first: the inspector may be a split of its own.
    private static func paneWidths(in root: NSView) -> [[Double]] {
        var widths: [[Double]] = []
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let split = view as? NSSplitView {
                widths.append(split.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 1 }
                    .map { Double($0.frame.width) })
            }
            queue += view.subviews
        }
        return widths
    }

    /// Whether some pane is as wide as the inspector's range allows, which no other column is.
    private static func showsInspector(_ root: NSView) -> Bool {
        let widths = paneWidths(in: root)
        print("click check: pane widths \(widths)")
        let range = ShellMetrics.inspector.minimum...ShellMetrics.inspector.maximum
        return widths.joined().contains { range.contains($0) }
    }

    /// A point in window coordinates, `leading` points in and `fromTop` below `pane`'s safe top.
    private static func point(in pane: NSView, fromTop: CGFloat, leading: CGFloat, in window: NSWindow) -> NSPoint {
        let safe = pane.convert(pane.safeAreaRect, to: nil)
        return NSPoint(x: safe.minX + leading, y: safe.maxY - fromTop)
    }

    /// A point in window coordinates, `leading` points in and `fromBottom` up from `pane`'s safe bottom.
    private static func point(in pane: NSView, fromBottom: CGFloat, leading: CGFloat, in window: NSWindow) -> NSPoint {
        let safe = pane.convert(pane.safeAreaRect, to: nil)
        return NSPoint(x: safe.minX + leading, y: safe.minY + fromBottom)
    }

    // MARK: Events

    private static func click(at point: NSPoint, in window: NSWindow) {
        print("click check: clicking \(point) in the window")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) {
                window.sendEvent(event)
            }
        }
    }

    private static func press(
        _ key     : String,
        keyCode   : UInt16,
        modifiers : NSEvent.ModifierFlags,
        in window : NSWindow,
        throughApp: Bool
    ) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
            ) else { continue }
            // A shortcut is matched by the application's key equivalents; a plain key goes to the window.
            if throughApp { NSApp.sendEvent(event) } else { window.sendEvent(event) }
        }
    }

    private static func expect(_ condition: Bool, _ failure: String) throws {
        guard condition else { throw CheckFailure(description: failure) }
    }
}

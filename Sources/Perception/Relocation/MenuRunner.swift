import Foundation
import AppKit
import AXSupport
import LocatorCore

/// EXECUTES one menu command by walking the AX menu tree along a title path and pressing the LEAF
/// AXMenuItem — the active counterpart to MenuHarvester's read-only enumeration. Menus are the one
/// surface where AX works even in otherwise AX-opaque apps (the menu bar is system-drawn), so this
/// verb is semantic end-to-end: no coordinates, no pixels. POLICY (active allowlist, destructive
/// gates) lives at the caller — this is the mechanism only.
public struct MenuRunner: Sendable {
    let ax: AXEngine
    public init(ax: AXEngine) { self.ax = ax }

    public enum Outcome: Equatable, Sendable {
        case pressed([String])       // executed; the resolved (exact-title) path
        case resolved([String])      // dry run: the full path resolves + leaf enabled — would press
        case notFound(String)        // which component failed to resolve
        case disabled(String)        // leaf found but disabled — refuse, don't force
        case submenu(String)         // the "leaf" is a container — pressing it would only flash the menu
    }

    /// Resolve `path` (case/whitespace-insensitive per component) down the live menu tree; press the
    /// leaf unless `execute` is false. Never presses intermediate items — the tree is READ down to the
    /// leaf (macOS populates it without showing menus), so nothing flashes on screen.
    @MainActor
    public func perform(path: [String], bundleID: String?, execute: Bool) -> Outcome {
        guard !path.isEmpty else { return .notFound("(empty path)") }
        guard let app = KnowledgeHarvester.resolveApp(bundleID: bundleID) else { return .notFound("app") }
        let appEl = ax.reader.applicationElement(pid: app.processIdentifier)
        ax.reader.setMessagingTimeout(appEl, seconds: 2)
        guard let menuBar = ax.menuBar(of: appEl) else { return .notFound("menu bar (app exposes no AX menus)") }

        var containers: [AXUIElement] = [menuBar]   // menuBar → AXMenuBarItems → AXMenu → AXMenuItems → …
        var resolved: [String] = []
        for (i, comp) in path.enumerated() {
            let want = KnowledgeText.normalize(comp)
            guard !want.isEmpty else { return .notFound(comp) }
            var found: (el: AXUIElement, title: String)?
            for c in containers.flatMap({ ax.reader.children($0) }) {
                let t = (ax.title(c) ?? "").trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, KnowledgeText.normalize(t) == want else { continue }
                found = (c, t); break
            }
            guard let (item, title) = found else { return .notFound(comp) }
            resolved.append(title)
            if i == path.count - 1 {
                // A leaf that HOLDS a submenu is a container, not a command — AXPress on it just opens
                // the menu on screen and we'd report false success (measured: Premiere "File > Export"
                // flashed the File menu, model declared victory, nothing happened).
                if !ax.reader.children(item).isEmpty { return .submenu(title) }
                if ax.reader.enabled(item) == false { return .disabled(title) }
                if !execute { return .resolved(resolved) }
                return ax.performPress(item) ? .pressed(resolved) : .notFound("press failed on '\(title)'")
            }
            containers = ax.reader.children(item)    // the item's AXMenu(s) hold the next level
        }
        return .notFound(path.joined(separator: " > "))
    }
}

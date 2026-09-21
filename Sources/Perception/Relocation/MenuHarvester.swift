import Foundation
import AppKit
import AXSupport
import LocatorCore

/// READ-ONLY enumeration of an app's menu bar into `MenuCommand`s — `children`/`copyAttr` only, NO synthetic
/// events, so it can never execute, toggle, open, or mutate anything. This is the SAFE CORE of the P3
/// auto-explorer: macOS populates the full AXMenuBar → AXMenuBarItem → AXMenu → AXMenuItem tree (titles,
/// shortcuts, enabled/mark state, submenus) without the menu ever being shown. @MainActor (AX is MainActor);
/// all reads, no capture/SCWindow, so no off-actor hop is needed.
public struct MenuHarvester: Sendable {
    let ax: AXEngine
    public init(ax: AXEngine) { self.ax = ax }

    @MainActor
    public func enumerate(bundleID: String?, now: Date, maxDepth: Int = 6, maxVisited: Int = 4000) -> (bundleID: String, commands: [MenuCommand])? {
        guard let app = KnowledgeHarvester.resolveApp(bundleID: bundleID), let bundle = app.bundleIdentifier else { return nil }
        let appEl = ax.reader.applicationElement(pid: app.processIdentifier)
        ax.reader.setMessagingTimeout(appEl, seconds: 2)
        guard let menuBar = ax.menuBar(of: appEl) else { return (bundle, []) }

        var out: [MenuCommand] = []
        var visited = 0
        // Seed the DFS with each top-level menu's AXMenu (child of its AXMenuBarItem).
        var stack: [(menu: AXUIElement, prefix: [String], top: String, depth: Int)] = []
        for barItem in ax.reader.children(menuBar) {
            let top = (ax.title(barItem) ?? "").trimmingCharacters(in: .whitespaces)
            guard !top.isEmpty else { continue }   // skip the Apple menu (empty title)
            for menu in ax.reader.children(barItem) { stack.append((menu, [top], top, 1)) }
        }
        while let frame = stack.popLast() {
            if visited >= maxVisited { break }
            for item in ax.reader.children(frame.menu) {   // AXMenuItem(s)
                if visited >= maxVisited { break }
                visited += 1
                let title = (ax.title(item) ?? "").trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }     // separators / unnamed
                let submenus = ax.reader.children(item)     // an AXMenu child ⇒ submenu parent
                let hasSub = !submenus.isEmpty
                let path = frame.prefix + [title]
                out.append(MenuCommand(path: path, topLevelTitle: frame.top, identifier: ax.identifier(item),
                                       hasSubmenu: hasSub, enabled: ax.reader.enabled(item) ?? true,
                                       markChar: ax.menuItemMarkChar(item), cmdChar: ax.menuItemCmdChar(item),
                                       firstSeen: now, lastSeen: now))
                if hasSub, frame.depth < maxDepth {
                    for sub in submenus { stack.append((sub, path, frame.top, frame.depth + 1)) }
                }
            }
        }
        return (bundle, out)
    }
}

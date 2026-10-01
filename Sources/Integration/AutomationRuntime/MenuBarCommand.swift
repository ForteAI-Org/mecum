//
//  MenuBarCommand.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AppKit
import ApplicationServices
import EngineCore
import PerceptionCore

/// MenuBarCommand lists or invokes a native path through the session's shared menu adapter.
/// General commands retain Elio's window-change readback. Only the explicit expected-window
/// route supplies typed memory evidence. A disabled Adobe menu may be refreshed before delivery;
/// the native command itself is requested at most once and remains bound to the Seat observation.
@MainActor
public enum MenuBarCommand {

    /// One item of a menu as the walk reads it.
    public struct Item<Element> {
        public let title    : String
        public let isEnabled: Bool?
        public let element  : Element

        public init(title: String, isEnabled: Bool?, element: Element) {
            self.title     = title
            self.isEnabled = isEnabled
            self.element   = element
        }
    }

    /// What one path names.
    public enum Resolution<Element> {
        case press(Element, path: String)
        case list(path: String, items: [String])
        /// The item reads disabled, which may be the application's menus gone stale.
        case disabled(path: String)
        case outcome(ActOutcome)
    }

    /// The items `path` passes through, split on ">".
    public static func steps(of path: String) -> [String] {
        path.split(separator: ">", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The walk, over any tree: `items` answers a node's items, the menu bar's first.
    public static func resolve<Element>(
        _ steps          : [String],
        from root        : Element,
        allowsDestructive: Bool,
        items            : (Element) -> [Item<Element>]
    ) -> Resolution<Element> {

        guard (1...8).contains(steps.count), steps.allSatisfy({ !normalized($0).isEmpty }) else {
            return .outcome(ActOutcome(.honestMiss, "Name a menu path such as \"File > Save As...\"."))
        }
        var level = items(root)
        var trail: [String] = []
        var chosen: Item<Element>?
        for (index, wanted) in steps.enumerated() {
            let shown = level.map(\.title).filter { !$0.isEmpty }
            let positions = level.indices.filter { normalized(level[$0].title) == normalized(wanted) }
            guard let position = positions.first else {
                let place = trail.isEmpty ? "the menu bar" : trail.joined(separator: " > ")
                return .outcome(ActOutcome(.honestMiss, "No item '\(wanted)' in \(place). It holds: "
                    + shown.prefix(40).joined(separator: ", ") + "."))
            }
            guard positions.count == 1 else {
                return .outcome(ActOutcome(.ambiguous, "Menu component '\(wanted)' is ambiguous."))
            }
            // The Apple menu is the bar's first item in every language.
            if index == 0, position == 0 {
                return .outcome(ActOutcome(.refused, "The Apple menu belongs to the system, not to the application."))
            }
            let match = level[position]
            trail.append(match.title)
            chosen = match
            level  = items(match.element)
        }
        let path = trail.joined(separator: " > ")
        guard let chosen else { return .outcome(ActOutcome(.honestMiss, "Name a menu path.")) }
        guard level.isEmpty else {
            return .list(path: path, items: level.filter { !$0.title.isEmpty }.map { item in
                item.title + (item.isEnabled == true ? "" : item.isEnabled == false ? " (disabled)" : " (unknown)") + (items(item.element).isEmpty ? "" : " >")
            })
        }
        // Before the enabled state, so the answer does not depend on it. Every step counts: Layer > Delete > Layer is destructive in its middle, not at its end.
        if !allowsDestructive, ActionPolicy.isDestructive(menuPath: trail) {
            return .outcome(ActOutcome(.refused, "\(path) reads as destructive, and the person has not allowed it."))
        }
        if chosen.isEnabled == false { return .disabled(path: path) }
        guard chosen.isEnabled == true else {
            return .outcome(ActOutcome(.refused, "\(path) has unknown availability."))
        }
        if normalized(chosen.title).hasPrefix("hide") {
            return .outcome(ActOutcome(.refused, "\(path) would hide the application's windows."))
        }
        return .press(chosen.element, path: path)
    }

    /// Case, the ellipsis and trailing dots do not tell two titles apart: "Save As…", "Save As..."
    /// and "save as" are one item.
    static func normalized(_ title: String) -> String {
        var text = title.lowercased().replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: The live menu bar

    /// Resolves `path` in the menu bar of `processID` and presses the item it names, or lists the
    /// menu it ends on. `pressed` is nil when nothing was pressed and the outcome says why.
    /// The refusal for an item that reads disabled. Measured on 30/09/2026: Photoshop left
    /// its whole File menu disabled after a dialog closed, re-enabled it only when it became
    /// active, and ignored a press on the disabled item.
    static func disabledRefusal(_ path: String) -> ActOutcome {
        ActOutcome(.refused, "\(path) is disabled right now. An application in the background can leave its "
            + "menus disabled after a dialog until it is brought forward; say so rather than concluding the "
            + "command is unavailable, and use a control in the window if there is one.")
    }

    /// Resolves once, optionally refreshes a disabled catalog before any delivery, then invokes
    /// the same Seat-bound adapter used by the strict expected-window route. Uncertain delivery
    /// never becomes success merely because the window list changes.
    public static func perform(
        _ path           : [String],
        menus            : any ApplicationMenuOperating,
        processID        : pid_t,
        allowsDestructive: Bool,
        refresh          : (() async -> Bool)? = nil,
        readWindows      : (() -> [String]?)? = nil,
        settle           : () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) },
        observe          : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome {
        func resolveCatalog() throws -> Resolution<[String]> {
            let catalog = try menus.catalog(processID: processID)
            guard catalog.isComplete else {
                return .outcome(ActOutcome(.refused, "The menu catalog is incomplete; observe before choosing a command."))
            }
            return resolve(path, from: [], allowsDestructive: allowsDestructive) { parent in
                catalog.items.filter { Array($0.path.dropLast()) == parent }.map { item in
                    Item(title: item.path.last ?? "", isEnabled: item.isEnabled, element: item.path)
                }
            }
        }
        var resolution = try resolveCatalog()
        if case .disabled = resolution, let refresh, await refresh() {
            try Task.checkCancellation()
            resolution = try resolveCatalog()
        }
        switch resolution {
        case .outcome(let outcome): return outcome
        case .disabled(let path): return disabledRefusal(path)
        case .list(let path, let items):
            return ActOutcome(.actedNoop, "\(path) holds: \(items.joined(separator: ", ")). Nothing was pressed.")
        case .press(let components, let title):
            let windows = readWindows ?? { windowSignature(of: processID) }
            let before = windows()
            try Task.checkCancellation()
            let delivery = try await menus.invoke(path: components, processID: processID)
            do {
                try await settle()
                let scene = try await observe()
                if case .uncertain(let reason) = delivery {
                    return ActOutcome(.actedUnverified, reason + " Observe; do not replay.", scene: scene)
                }
                let changed = windowsChanged(before: before, after: windows())
                return ActOutcome(changed ? .foundActed : .actedUnverified,
                    "Requested \(title): " + (changed
                        ? "an application window opened, closed or was retitled. This is not typed goal evidence."
                        : "no complete window change was verified. Observe; do not replay."), scene: scene)
            } catch is CancellationError { throw CancellationError() }
            catch {
                return ActOutcome(.actedUnverified, "Menu was requested but readback failed: \(error). Do not replay.")
            }
        }
    }

    /// Requires two complete inventories. Reordering alone is not a window change.
    public static func windowsChanged(before: [String]?, after: [String]?) -> Bool {
        guard let before, let after else { return false }
        return before.sorted() != after.sorted()
    }

    /// What says a command changed the application's windows: every accessibility window's role,
    /// subrole and title, in order. A dialog opening or closing, or a document retitling, moves it.
    public static func windowSignature(of processID: pid_t) -> [String]? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        return windows.map { window in
            [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute]
                .map { string(window, $0) ?? "" }.joined(separator: "|")
        }
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

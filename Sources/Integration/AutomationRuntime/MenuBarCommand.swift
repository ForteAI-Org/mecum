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

/// MenuBarCommand reaches one item of an application's menu bar through accessibility, which
/// answers for an application in the background: nothing is clicked, nothing is activated.
///
/// Measured on 30/09/2026 with Photoshop 27.10 behind the person's application: its whole menu
/// bar read, enabled states included, and `AXPress` on Layer > New > Layer... returned success
/// and opened the New Layer dialog while the person's application stayed in front. A window
/// that shows no control for a command (Photoshop's document tab has no × in the scene) still
/// has the command in its menu.
///
/// A path that ends on a menu lists its items and presses nothing; one that ends on an item
/// presses it. The Apple menu is the system's and is refused, and so are an item that is
/// disabled, one that hides the application, and one on a path `ActionPolicy` reads as
/// destructive at any step unless the person allowed that.
@MainActor
public enum MenuBarCommand {

    /// One item of a menu as the walk reads it.
    public struct Item<Element> {
        public let title    : String
        public let isEnabled: Bool
        public let element  : Element

        public init(title: String, isEnabled: Bool, element: Element) {
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
        path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The walk, over any tree: `items` answers a node's items, the menu bar's first.
    public static func resolve<Element>(
        _ steps          : [String],
        from root        : Element,
        allowsDestructive: Bool,
        items            : (Element) -> [Item<Element>]
    ) -> Resolution<Element> {

        guard !steps.isEmpty else {
            return .outcome(ActOutcome(.honestMiss, "Name a menu path such as \"File > Save As...\"."))
        }
        var level = items(root)
        var trail: [String] = []
        var chosen: Item<Element>?
        for (index, wanted) in steps.enumerated() {
            let shown = level.map(\.title).filter { !$0.isEmpty }
            guard let position = level.firstIndex(where: { normalized($0.title) == normalized(wanted) }) else {
                let place = trail.isEmpty ? "the menu bar" : trail.joined(separator: " > ")
                return .outcome(ActOutcome(.honestMiss, "No item '\(wanted)' in \(place). It holds: "
                    + shown.prefix(40).joined(separator: ", ") + "."))
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
                item.title + (item.isEnabled ? "" : " (disabled)") + (items(item.element).isEmpty ? "" : " >")
            })
        }
        // Before the enabled state, so the answer does not depend on it. Every step counts: Layer > Delete > Layer is destructive in its middle, not at its end.
        if !allowsDestructive, trail.contains(where: { ActionPolicy.isDestructive(label: $0) }) {
            return .outcome(ActOutcome(.refused, "\(path) reads as destructive, and the person has not allowed it."))
        }
        guard chosen.isEnabled else { return .disabled(path: path) }
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

    public static func run(
        _ path           : String,
        processID        : pid_t,
        allowsDestructive: Bool
    ) -> (pressed: String?, outcome: ActOutcome, disabled: Bool) {

        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let bar = element(application, kAXMenuBarAttribute) else {
            return (nil, ActOutcome(.honestMiss, "This application shows no menu bar to accessibility."), false)
        }
        switch resolve(steps(of: path), from: bar, allowsDestructive: allowsDestructive, items: menuItems) {
            case .outcome(let outcome):
                return (nil, outcome, false)
            case .disabled(let path):
                return (nil, disabledRefusal(path), true)
            case .list(let path, let items):
                return (nil, ActOutcome(.actedNoop, "\(path) holds: \(items.joined(separator: ", ")). "
                    + "Nothing was pressed: name one of them to press it."), false)
            case .press(let item, let path):
                let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
                // An item that opens a modal can keep the reply past the timeout: it was pressed.
                guard error == .success || error == .cannotComplete else {
                    return (nil, ActOutcome(.actedUnverified, "Pressing \(path) failed with AXError \(error.rawValue)."),
                            false)
                }
                return (path, ActOutcome(.foundActed, "pressed \(path)"), false)
        }
    }

    /// Runs `path` and, when it pressed an item, observes the scene after it. Pressing is verified
    /// by the application's windows: a dialog, a closed document or a new title moved them.
    ///
    /// `refresh` is what an application whose menus go stale in the background is given:
    /// a moment in front, so it recomputes them. It runs once, only for an item that read
    /// disabled, and the item is read again after it.
    public static func perform(
        _ path           : String,
        processID        : pid_t,
        allowsDestructive: Bool,
        refresh          : (() async -> Bool)? = nil,
        observe          : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome {

        let before = windowSignature(of: processID)
        var (pressed, outcome, disabled) = run(path, processID: processID, allowsDestructive: allowsDestructive)
        if disabled, let refresh, await refresh() {
            (pressed, outcome, disabled) = run(path, processID: processID, allowsDestructive: allowsDestructive)
        }
        guard let pressed else { return outcome }
        try? await Task.sleep(for: .milliseconds(400))
        let scene   = try await observe()
        let changed = windowSignature(of: processID) != before
        return changed
            ? ActOutcome(.foundActed, "pressed \(pressed): a window of the application opened, closed or was retitled",
                         scene: scene)
            : ActOutcome(.actedUnverified, "pressed \(pressed): no window opened, closed or was retitled; "
                         + "the scene shows whether it took effect. Do not press it again blind.", scene: scene)
    }

    /// What says a command changed the application's windows: every accessibility window's role,
    /// subrole and title, in order. A dialog opening or closing, or a document retitling, moves it.
    public static func windowSignature(of processID: pid_t) -> [String] {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        return windows.map { window in
            [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute]
                .map { string(window, $0) ?? "" }.joined(separator: "|")
        }
    }

    /// A menu bar item's or menu item's items: the children of its one `AXMenu`, or the menu
    /// bar's own children for the bar.
    private static func menuItems(of node: AXUIElement) -> [Item<AXUIElement>] {
        var children = elements(node, kAXChildrenAttribute)
        if string(node, kAXRoleAttribute) != (kAXMenuBarRole as String) {
            guard let menu = children.first(where: { string($0, kAXRoleAttribute) == (kAXMenuRole as String) })
            else { return [] }
            children = elements(menu, kAXChildrenAttribute)
        }
        return children.map { child in
            var enabled: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXEnabledAttribute as CFString, &enabled)
            return Item(title: string(child, kAXTitleAttribute) ?? "",
                        isEnabled: (enabled as? Bool) ?? true,
                        element: child)
        }
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elements(_ node: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

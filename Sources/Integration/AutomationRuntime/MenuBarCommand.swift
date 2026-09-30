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

    /// What giving the application a moment in front answered, for an item that read disabled.
    public enum Refresh: Sendable, Equatable {
        /// The item read enabled before the front went back: read it again and press it.
        case readAgain
        /// The item stays disabled. `reason` is one sentence appended to the refusal, saying why the
        /// application was not brought forward or what its moment in front left; nil when it was
        /// brought forward and the item simply stayed disabled.
        case stillDisabled(reason: String?)
        /// The item is disabled because a dialog of the application is open: the refusal says
        /// that instead of the one about menus left stale in the background.
        case blockedByDialog
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

    /// Whether `steps` name an item that reads enabled and would be pressed, over any tree. The
    /// destructive policy is not asked: a path it refuses never reads as disabled, so it never
    /// reaches the question. A missing, disabled or refused item, and a menu, are not enabled.
    public static func isEnabled<Element>(
        _ steps  : [String],
        from root: Element,
        items    : (Element) -> [Item<Element>]
    ) -> Bool {
        if case .press = resolve(steps, from: root, allowsDestructive: true, items: items) { return true }
        return false
    }

    /// Whether `path` names an enabled item of the menu bar of `processID`, read for a 20 ms poll:
    /// false means not enabled yet, never a failure, and the poll keeps asking.
    ///
    /// Measured on 30/09/2026 with Photoshop 27.10 brought in front with its menus stale: File >
    /// Save As... read disabled at 5 ms, every read of the menu bar answered -25204
    /// (`cannotComplete`) from 61 ms to 961 ms while it recomputed them, and it read enabled at
    /// 1050 ms. So every element is read with a short `timeout`, an unreadable menu bar or item
    /// is not enabled yet, and a walk stops at the first item that does not answer: an
    /// application that goes busy in the middle of it costs one timeout, not one per element,
    /// and the main actor the poll runs on is not held for seconds.
    public static func isEnabled(_ path: String, processID: pid_t, timeout: Float = 0.1) -> Bool {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, timeout)
        guard let bar = element(application, kAXMenuBarAttribute) else { return false }
        AXUIElementSetMessagingTimeout(bar, timeout)
        return isEnabled(steps(of: path), from: bar) { menuItems(of: $0, pollTimeout: timeout) }
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

    /// The refusal for an item that reads disabled. Measured on 30/09/2026: Photoshop left
    /// its whole File menu disabled after a dialog closed, re-enabled it only when it became
    /// active, and ignored a press on the disabled item.
    static func disabledRefusal(_ path: String) -> ActOutcome {
        ActOutcome(.refused, "\(path) is disabled right now. An application in the background can leave its "
            + "menus disabled after a dialog until it is brought forward; say so rather than concluding the "
            + "command is unavailable, and use a control in the window if there is one.")
    }

    /// The refusal for an item disabled because a dialog of the application is open, which is
    /// the application's own reason and not a stale menu.
    static func dialogRefusal(_ path: String) -> ActOutcome {
        ActOutcome(.refused, "\(path) is disabled because a dialog of the application is open: "
            + "answer or close the dialog first.")
    }

    /// Resolves `path` in the menu bar of `processID` and presses the item it names, or lists the
    /// menu it ends on. `pressed` is nil when nothing was pressed and the outcome says why;
    /// `disabled` is the item's path as the menu spells it when that reason is that it reads disabled.
    public static func run(
        _ path           : String,
        processID        : pid_t,
        allowsDestructive: Bool
    ) -> (pressed: String?, outcome: ActOutcome, disabled: String?) {

        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let bar = element(application, kAXMenuBarAttribute) else {
            return (nil, ActOutcome(.honestMiss, "This application shows no menu bar to accessibility."), nil)
        }
        switch resolve(steps(of: path), from: bar, allowsDestructive: allowsDestructive, items: { menuItems(of: $0) }) {
            case .outcome(let outcome):
                return (nil, outcome, nil)
            case .disabled(let path):
                return (nil, disabledRefusal(path), path)
            case .list(let path, let items):
                return (nil, ActOutcome(.actedNoop, "\(path) holds: \(items.joined(separator: ", ")). "
                    + "Nothing was pressed: name one of them to press it."), nil)
            case .press(let item, let path):
                let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
                // An item that opens a modal can keep the reply past the timeout: it was pressed.
                guard error == .success || error == .cannotComplete else {
                    return (nil, ActOutcome(.actedUnverified, "Pressing \(path) failed with AXError \(error.rawValue)."),
                            nil)
                }
                return (path, ActOutcome(.foundActed, "pressed \(path)"), nil)
        }
    }

    /// Runs `path` and, when it pressed an item, observes the scene after it. Pressing is verified
    /// by the application's windows: a dialog, a closed document or a new title moved them.
    ///
    /// `refresh` is what an application whose menus go stale in the background is given:
    /// a moment in front, so it recomputes them. It runs once, only for an item that read
    /// disabled. The item is read again after it when it answers `readAgain`; for an open dialog
    /// the refusal becomes the dialog's; otherwise the disabled refusal stands, with the reason it
    /// gives appended.
    public static func perform(
        _ path           : String,
        processID        : pid_t,
        allowsDestructive: Bool,
        refresh          : (() async -> Refresh)? = nil,
        observe          : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome {

        let before = windowSignature(of: processID)
        var (pressed, outcome, disabled) = run(path, processID: processID, allowsDestructive: allowsDestructive)
        if let disabledPath = disabled, let refresh {
            switch await refresh() {
                case .readAgain:
                    (pressed, outcome, disabled) = run(path, processID: processID, allowsDestructive: allowsDestructive)
                case .stillDisabled(let reason?):
                    outcome = ActOutcome(outcome.kind, outcome.message + " " + reason)
                case .stillDisabled(nil):
                    break
                case .blockedByDialog:
                    outcome = dialogRefusal(disabledPath)
            }
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
    ///
    /// `pollTimeout` makes it the reading of a poll: the timeout is set on every element read,
    /// since accessibility keeps one per element; the first item that answers `cannotComplete`
    /// ends the reading with no items, since a busy application answers every read only at its
    /// timeout; and an enabled state that does not answer reads as disabled, where `run` reads
    /// it as enabled.
    private static func menuItems(of node: AXUIElement, pollTimeout: Float? = nil) -> [Item<AXUIElement>] {
        var children = elements(node, kAXChildrenAttribute, timeout: pollTimeout)
        if string(node, kAXRoleAttribute) != (kAXMenuBarRole as String) {
            guard let menu = children.first(where: { string($0, kAXRoleAttribute) == (kAXMenuRole as String) })
            else { return [] }
            children = elements(menu, kAXChildrenAttribute, timeout: pollTimeout)
        }
        var items: [Item<AXUIElement>] = []
        for child in children {
            var enabled: CFTypeRef?
            let answer = AXUIElementCopyAttributeValue(child, kAXEnabledAttribute as CFString, &enabled)
            if pollTimeout != nil, answer == .cannotComplete { return [] }
            items.append(Item(title    : string(child, kAXTitleAttribute) ?? "",
                              isEnabled: (enabled as? Bool) ?? (pollTimeout == nil),
                              element  : child))
        }
        return items
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elements(_ node: AXUIElement, _ name: String, timeout: Float? = nil) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return [] }
        let found = (value as? [AXUIElement]) ?? []
        if let timeout { found.forEach { AXUIElementSetMessagingTimeout($0, timeout) } }
        return found
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

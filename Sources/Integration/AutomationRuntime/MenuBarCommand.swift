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

    /// One item of a menu as the walk reads it. The key equivalent is read only by the walk that
    /// looks for a new window: `keyEquivalent` is `AXMenuItemCmdChar`, nil when the item has none,
    /// and `keyEquivalentModifiers` is `AXMenuItemCmdModifiers`, where 0 is Command alone, 1 adds
    /// Shift, 2 Option, 4 Control and 8 takes Command away.
    public struct Item<Element> {
        public let title                 : String
        public let isEnabled             : Bool
        public let element               : Element
        public let keyEquivalent         : String?
        public let keyEquivalentModifiers: Int

        public init(
            title                 : String,
            isEnabled             : Bool,
            element               : Element,
            keyEquivalent         : String? = nil,
            keyEquivalentModifiers: Int     = 0
        ) {
            self.title                  = title
            self.isEnabled              = isEnabled
            self.element                = element
            self.keyEquivalent          = keyEquivalent
            self.keyEquivalentModifiers = keyEquivalentModifiers
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
            let exact = level.firstIndex(where: { normalized($0.title) == normalized(wanted) })
            let verb = normalized(wanted)
            // AppKit validates Redo into Redo Typing on activation. Only these
            // two bare editing verbs admit one terminal word-boundary suffix;
            // the exact title, including its disabled state, always wins.
            let dynamic = index > 0 && index == steps.count - 1 && ["undo", "redo"].contains(verb)
                ? level.indices.filter { normalized(level[$0].title).hasPrefix(verb + " ") } : []
            if exact == nil, dynamic.count > 1 {
                return .outcome(ActOutcome(.ambiguous, "More than one current '\(wanted)' command: "
                    + dynamic.map { level[$0].title }.joined(separator: ", ") + ". Name its exact title."))
            }
            guard let position = exact ?? (dynamic.count == 1 ? dynamic.first : nil) else {
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

    /// The item that opens a new window of the application, found by its key equivalent because
    /// titles are localized and the key is not: an enabled item whose key is N with Command held,
    /// in the menus after the Apple menu and the application's own.
    ///
    /// Shift on it is the private window by convention (Chrome's Incognito and Safari's Private
    /// Window are both Shift-Command-N), so an item with Shift is never taken. Of the rest the
    /// lowest `keyEquivalentModifiers` wins, which is Command alone, then Option, then Control, and
    /// the bar's order breaks a tie. Measured on 30/09/2026, Safari with profiles has no Command-N:
    /// New Personal Window is Option-Command-N and New Empty Tab Group, which opens no window, is
    /// Control-Command-N. A submenu is not looked into.
    public static func newWindowItem<Element>(
        from root: Element,
        items    : (Element) -> [Item<Element>]
    ) -> (element: Element, path: String)? {

        // Shift (1) and no Command (8): the header's constants for them are not imported into Swift.
        let excluded = 1 | 8
        var best: (element: Element, path: String, modifiers: Int)?
        for menu in items(root).dropFirst(2) {
            for item in items(menu.element) where item.isEnabled
                && item.keyEquivalent?.lowercased() == "n"
                && item.keyEquivalentModifiers & excluded == 0
                && item.keyEquivalentModifiers < (best?.modifiers ?? .max) {
                let path = "\(menu.title) > \(item.title)"
                // Nothing beats Command alone, so the rest of the bar is not read.
                if item.keyEquivalentModifiers == 0 { return (item.element, path) }
                best = (item.element, path, item.keyEquivalentModifiers)
            }
        }
        return best.map { ($0.element, $0.path) }
    }

    /// Presses `newWindowItem` in the menu bar of `processID` and answers the item's path. An
    /// application in the background stays there: measured on 30/09/2026 with Chrome and Safari
    /// behind the person's application, the front application never changed. Throws when there is
    /// no menu bar or no such item, having pressed nothing, and when the press answers an error.
    public static func pressNewWindow(processID: pid_t) throws -> String {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let bar = element(application, kAXMenuBarAttribute) else {
            throw AutomationFailure("It shows no menu bar to accessibility.")
        }
        guard let (item, path) = newWindowItem(from: bar, items: { menuItems(of: $0, readsKeyEquivalents: true) })
        else {
            throw AutomationFailure("No enabled item of its menu bar opens a new window with Command-N.")
        }
        let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard error == .success || error == .cannotComplete else {
            throw AutomationFailure("Pressing \(path) failed with AXError \(error.rawValue).")
        }
        return path
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
        run(resolve(path, processID: processID, allowsDestructive: allowsDestructive)) {
            AXUIElementPerformAction($0, kAXPressAction as CFString)
        }
    }

    private static func resolve(
        _ path: String, processID: pid_t, allowsDestructive: Bool
    ) -> Resolution<AXUIElement> {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let bar = element(application, kAXMenuBarAttribute) else {
            return .outcome(ActOutcome(.honestMiss, "This application shows no menu bar to accessibility."))
        }
        return resolve(steps(of: path), from: bar, allowsDestructive: allowsDestructive, items: { menuItems(of: $0) })
    }

    private static func run<Element>(
        _ resolution: Resolution<Element>, press: (Element) -> AXError
    ) -> (pressed: String?, outcome: ActOutcome, disabled: String?) {
        switch resolution {
            case .outcome(let outcome):
                return (nil, outcome, nil)
            case .disabled(let path):
                return (nil, disabledRefusal(path), path)
            case .list(let path, let items):
                return (nil, ActOutcome(.actedNoop, "\(path) holds: \(items.joined(separator: ", ")). "
                    + "Nothing was pressed: name one of them to press it."), nil)
            case .press(let item, let path):
                let error = press(item)
                // An item that opens a modal can keep the reply past the timeout: it was pressed.
                guard error == .success || error == .cannotComplete else {
                    return (nil, ActOutcome(.actedUnverified, "Pressing \(path) failed with AXError \(error.rawValue)."),
                            nil)
                }
                return (path, ActOutcome(.foundActed, "pressed \(path)"), nil)
        }
    }

    /// Prepares a command before its only dispatch, then resolves its current
    /// item again. Listing and refused paths never request preparation.
    static func runPrepared<Element>(
        preparesEnabledItems: Bool,
        read: () -> Resolution<Element>,
        press: (Element) -> AXError,
        refresh: (() async -> Refresh)?
    ) async -> (pressed: String?, outcome: ActOutcome, disabled: String?) {
        var resolution = read()
        var didRefresh = false
        if preparesEnabledItems, case .press(_, let path) = resolution, let refresh {
            didRefresh = true
            switch await refresh() {
                case .readAgain:
                    resolution = read()
                case .stillDisabled(let reason):
                    let message = "\(path) was not dispatched because menu preparation did not complete."
                    return (nil, ActOutcome(.refused, message + (reason.map { " " + $0 } ?? "")), nil)
                case .blockedByDialog:
                    return (nil, dialogRefusal(path), nil)
            }
        }
        var (pressed, outcome, disabled) = run(resolution, press: press)
        if !didRefresh, let disabledPath = disabled, let refresh {
            switch await refresh() {
                case .readAgain:
                    (pressed, outcome, disabled) = run(read(), press: press)
                case .stillDisabled(let reason?):
                    outcome = ActOutcome(outcome.kind, outcome.message + " " + reason)
                case .stillDisabled(nil):
                    break
                case .blockedByDialog:
                    outcome = dialogRefusal(disabledPath)
            }
        }
        return (pressed, outcome, disabled)
    }

    /// Resolves an admitted command again inside its bounded foreground scope.
    /// Listings warn that their unprepared metadata may be stale. Listings,
    /// misses and policy refusals never enter the scope. `withFront`
    /// invokes its callback at most once and returns any readiness or handback
    /// failure. A dispatched command retains that failure as a possible partial
    /// effect; it is never pressed again after the scope ends.
    static func runInFront<Element>(
        read     : @escaping () -> Resolution<Element>,
        press    : @escaping (Element) -> AXError,
        withFront: (@escaping @MainActor () -> Void) async -> String?
    ) async -> (pressed: String?, outcome: ActOutcome, disabled: String?) {
        let initial = read()
        switch initial {
            case .press, .disabled: break
            case .list:
                let result = run(initial, press: press)
                return (nil, ActOutcome(result.outcome.kind, result.outcome.message
                    + " This listing was read without activating the application; enabled flags and editing history "
                    + "may be stale. Use the full command path for the intended operation; menu preparation reads "
                    + "its current item again."), result.disabled)
            case .outcome:
                return run(initial, press: press)
        }
        var result: (pressed: String?, outcome: ActOutcome, disabled: String?)?
        let issue = await withFront {
            guard result == nil else { return }
            result = run(read(), press: press)
        }
        guard let result else {
            return (nil, ActOutcome(.refused, issue ?? "Menu preparation did not dispatch the command."), nil)
        }
        guard let issue else { return result }
        let mayHaveActed = result.pressed != nil || result.outcome.kind == .actedUnverified
        return (result.pressed, ActOutcome(
            mayHaveActed ? .actedUnverified : .refused,
            result.outcome.message + " " + issue + (mayHaveActed ? " Do not repeat it blind." : "")
        ), result.disabled)
    }

    /// Performs an admitted menu command once during the consumer-supplied
    /// foreground scope, then observes its effect after handback. Input is
    /// separate from readiness, and cleanup failure stays in the outcome.
    /// `frontReturned` is read once, after the observation: a handback that
    /// was not verified when the scope ended may be verified by then.
    public static func performInFront(
        _ path           : String,
        processID        : pid_t,
        allowsDestructive: Bool,
        withFront        : (@escaping @MainActor () -> Void) async -> String?,
        frontReturned    : () -> Bool,
        observe          : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome {
        let before = windowSignature(of: processID)
        var frontIssue: String?
        let (pressed, outcome, _) = await runInFront(
            read: { resolve(path, processID: processID, allowsDestructive: allowsDestructive) },
            press: { AXUIElementPerformAction($0, kAXPressAction as CFString) },
            withFront: { command in
                frontIssue = await withFront(command)
                return frontIssue
            }
        )
        return try await observedOutcome(
            pressed,
            outcome      : outcome,
            processID    : processID,
            before       : before,
            frontIssue   : frontIssue,
            frontReturned: frontReturned,
            observe      : observe
        )
    }

    /// Runs `path` and, when it pressed an item, observes the scene after it. Pressing is verified
    /// by the application's windows: a dialog, a closed document or a new title moved them.
    ///
    /// `refresh` is what an application whose menus go stale in the background is given:
    /// a moment in front, so it recomputes them. It runs once, only for an item that read
    /// disabled, or before an enabled command when `preparesEnabledItems` is true.
    /// The item is read again after it when it answers `readAgain`; for an open dialog
    /// the refusal becomes the dialog's; otherwise the disabled refusal stands, with the reason it
    /// gives appended.
    public static func perform(
        _ path           : String,
        processID        : pid_t,
        allowsDestructive: Bool,
        refresh          : (() async -> Refresh)? = nil,
        preparesEnabledItems: Bool = false,
        observe          : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome {

        let before = windowSignature(of: processID)
        let (pressed, outcome, _) = await runPrepared(
            preparesEnabledItems: preparesEnabledItems,
            read: { resolve(path, processID: processID, allowsDestructive: allowsDestructive) },
            press: { AXUIElementPerformAction($0, kAXPressAction as CFString) },
            refresh: refresh
        )
        return try await observedOutcome(pressed, outcome: outcome, processID: processID, before: before, observe: observe)
    }

    /// Retains an acknowledged dispatch even when its later observation fails.
    ///
    /// `frontIssue` is what the foreground scope reported after the press. When
    /// `frontReturned` then reads true the scope's issue is over and the
    /// window verdict applies. When it reads false the scene is attached and the
    /// message does not ask for another observation (ADR 0033).
    static func observedOutcome(
        _ pressed    : String?,
        outcome      : ActOutcome,
        processID    : pid_t,
        before       : [String],
        frontIssue   : String? = nil,
        frontReturned: () -> Bool = { false },
        observe      : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome {
        guard let pressed else { return outcome }
        try? await Task.sleep(for: .milliseconds(400))
        let scene: SceneSnapshot
        do {
            scene = try await observe()
        } catch {
            return ActOutcome(.actedUnverified, outcome.message
                + " Observation after dispatch failed: \(error). Do not repeat this command. "
                + "Observe the session before further input. If observation stays unavailable, "
                + "stop and report this error.")
        }
        if outcome.kind == .actedUnverified, !(frontIssue != nil && frontReturned()) {
            guard let frontIssue else { return ActOutcome(.actedUnverified, outcome.message, scene: scene) }
            return ActOutcome(.actedUnverified, (pressed.hasSuffix(".") ? "pressed \(pressed)" : "pressed \(pressed).")
                + " \(frontIssue) The scene is attached."
                + " The seat accepts no input until the front is back with the person's window."
                + " Do not repeat it blind.", scene: scene)
        }
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
    /// it as enabled. `readsKeyEquivalents` reads each item's key equivalent as well.
    private static func menuItems(
        of node            : AXUIElement,
        pollTimeout        : Float? = nil,
        readsKeyEquivalents: Bool   = false
    ) -> [Item<AXUIElement>] {
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
            var modifiers: CFTypeRef?
            if readsKeyEquivalents {
                AXUIElementCopyAttributeValue(child, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
            }
            items.append(Item(title                 : string(child, kAXTitleAttribute) ?? "",
                              isEnabled             : (enabled as? Bool) ?? (pollTimeout == nil),
                              element               : child,
                              keyEquivalent         : readsKeyEquivalents
                                  ? string(child, kAXMenuItemCmdCharAttribute) : nil,
                              keyEquivalentModifiers: (modifiers as? NSNumber)?.intValue ?? 0))
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

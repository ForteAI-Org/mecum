//
//  DialogButtonPress.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AppKit
import ApplicationServices
import EngineCore
import PerceptionCore
import WindowPlacement

/// DialogButtonPress presses one button of the application's current dialog or alert by its
/// title, through accessibility. It is the explicit route for a button the seat cannot deliver
/// a click to, and never a fallback a click takes on its own.
///
/// Measured on 30/09/2026 with Photoshop: the "already exists, replace it?" alert over its Save
/// panel was drawn by the panel service at the position Photoshop last reported, which Photoshop
/// had not updated after the seat moved the panel. Every click and key to it was refused with
/// `geometryUnavailable`, and its Cancel and Replace showed as text. Both were `AXButton`s of
/// Photoshop with `AXPress`, and pressing Cancel closed the alert.
///
/// The scope searched is the dialogs the seat holds when it holds any, and the application's
/// focused window only when it holds none: a button of a window behind a dialog is not what the
/// person sees answering. Measured on 30/09/2026 with Photoshop, right after File > Close opened
/// its "Save changes?" alert: the focused window was still the document, so `Save` was looked
/// for among the document's buttons.
@MainActor
public enum DialogButtonPress {

    /// One button as the search reads it.
    public struct Button<Element> {
        public let title    : String
        public let isEnabled: Bool
        public let element  : Element

        public init(title: String, isEnabled: Bool, element: Element) {
            self.title     = title
            self.isEnabled = isEnabled
            self.element   = element
        }
    }

    /// What one title names among the buttons read.
    public enum Resolution<Element> {
        case press(Element, title: String)
        case outcome(ActOutcome)
    }

    /// The choice, over any list: exactly one enabled button with the title, compared like menu
    /// titles, and nothing destructive unless the person allowed it.
    public static func resolve<Element>(
        _ title          : String,
        among buttons    : [Button<Element>],
        allowsDestructive: Bool
    ) -> Resolution<Element> {

        let shown   = buttons.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ")
        let matches = buttons.filter { MenuBarCommand.normalized($0.title) == MenuBarCommand.normalized(title) }
        guard let only = matches.first else {
            let listing = shown.isEmpty ? "It has no buttons accessibility can read." : "Its buttons: \(shown)."
            return .outcome(ActOutcome(.honestMiss, "No button '\(title)' in the dialog in front. " + listing))
        }
        guard matches.count == 1 else {
            return .outcome(ActOutcome(.ambiguous, "\(matches.count) buttons are titled '\(title)' in the dialog in front."))
        }
        if !allowsDestructive, ActionPolicy.isDestructive(label: only.title) {
            return .outcome(ActOutcome(.refused, "'\(only.title)' reads as destructive, and the person has not allowed it."))
        }
        guard only.isEnabled else {
            return .outcome(ActOutcome(.refused, "'\(only.title)' is disabled right now."))
        }
        return .press(only.element, title: only.title)
    }

    /// The windows one press searches: the dialogs the seat holds, by Window ID, when it holds
    /// any, and the application's focused window only when it holds none. It is a scope and not a
    /// fallback, so a held dialog accessibility cannot find is left out, never replaced.
    public static func scope<Window>(
        dialogs      : [Int],
        window       : (Int) -> Window?,
        focusedWindow: () -> Window?
    ) -> [Window] {
        dialogs.isEmpty ? (focusedWindow().map { [$0] } ?? []) : dialogs.compactMap(window)
    }

    /// Presses `title` in the scope `dialogs` names in `processID`, the Window IDs of the dialogs
    /// the seat holds, and observes the scene after it, verified like a menu item: by the
    /// application's windows.
    public static func perform(
        _ title          : String,
        processID        : pid_t,
        dialogs          : [Int],
        allowsDestructive: Bool,
        observe          : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome {

        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        let listed  = dialogs.isEmpty ? [] : windowsAndSheets(of: application)
        let windows = scope(
            dialogs      : dialogs,
            window       : { number in listed.first { WindowRelocator.windowNumber(of: $0) == number } },
            focusedWindow: { element(application, kAXFocusedWindowAttribute) }
        )
        guard !windows.isEmpty else {
            return ActOutcome(.honestMiss, dialogs.isEmpty
                ? "The application has no window in front that accessibility can read."
                : "The dialog open in the seat is not one accessibility can read.")
        }

        switch resolve(title, among: windows.flatMap(buttons(in:)), allowsDestructive: allowsDestructive) {
            case .outcome(let outcome):
                return outcome
            case .press(let button, let title):
                let before = MenuBarCommand.windowSignature(of: processID)
                let error  = AXUIElementPerformAction(button, kAXPressAction as CFString)
                // A button that opens a modal can keep the reply past the timeout: it was pressed.
                guard error == .success || error == .cannotComplete else {
                    return ActOutcome(
                        .actedUnverified,
                        "Pressing '\(title)' failed with AXError \(error.rawValue).",
                        check: MenuBarCommand.windowCheck(.unknown, limits: [.deliveryUncertain], performed: .uncertain)
                    )
                }
                try? await Task.sleep(for: .milliseconds(400))
                let scene   = try await observe()
                let changed = MenuBarCommand.windowSignature(of: processID) != before
                let check   = MenuBarCommand.windowCheck(changed ? .passed : .unknown)
                return changed
                    ? ActOutcome(.foundActed, "pressed '\(title)': a window of the application opened, closed or "
                        + "was retitled", scene: scene, check: check)
                    : ActOutcome(.actedUnverified, "pressed '\(title)': no window opened, closed or was retitled; "
                        + "the scene shows whether it took effect. Do not press it again blind.",
                        scene: scene, check: check)
        }
    }

    /// Every `AXButton` under `window`, bounded: a dialog holds a handful, and a window that
    /// holds thousands of elements is not the dialog this is for.
    private static func buttons(in window: AXUIElement) -> [Button<AXUIElement>] {
        var found: [Button<AXUIElement>] = []
        var pending: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (node, depth) = pending.popLast(), visited < 2_000 {
            visited += 1
            if string(node, kAXRoleAttribute) == (kAXButtonRole as String) {
                var enabled: CFTypeRef?
                AXUIElementCopyAttributeValue(node, kAXEnabledAttribute as CFString, &enabled)
                found.append(Button(title: string(node, kAXTitleAttribute) ?? "",
                                    isEnabled: (enabled as? Bool) ?? true,
                                    element: node))
            }
            guard depth < 10 else { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                  let elements = children as? [AXUIElement]
            else { continue }
            pending.append(contentsOf: elements.map { ($0, depth + 1) })
        }
        return found
    }

    /// The application's `AXWindows` entries and the sheets attached to them, which accessibility
    /// lists as children of their window and not as windows of their own.
    private static func windowsAndSheets(of application: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        return windows + windows.flatMap { window in
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
                  let elements = children as? [AXUIElement]
            else { return [AXUIElement]() }
            return elements.filter { string($0, kAXRoleAttribute) == (kAXSheetRole as String) }
        }
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

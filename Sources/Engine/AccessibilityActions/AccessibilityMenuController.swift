import ApplicationServices
import EngineCore
import Foundation

/// AccessibilityMenuController reads the menu bar without opening it. It retains AX handles only
/// during a call. Execution walks an exact, unique path afresh and presses only its enabled leaf.
@MainActor
public struct AccessibilityMenuController {
    public init() {}

    public func catalog(processID: pid_t) throws -> MenuCatalog {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let bar = try element(application, kAXMenuBarAttribute)
        var items: [MenuCatalog.Item] = []
        var issues: [String] = []
        var visited = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        func walk(_ parent: AXUIElement, _ path: [String], _ ancestorsEnabled: Bool?) {
            guard path.count < 8, visited < 4000, ContinuousClock.now < deadline else {
                issues.append("Menu traversal limit reached."); return
            }
            do {
                for child in try children(parent) {
                    visited += 1
                    guard visited <= 4000, ContinuousClock.now < deadline else {
                        issues.append("Menu traversal limit reached."); return
                    }
                    let role = try string(child, kAXRoleAttribute)
                    if role == kAXMenuRole { walk(child, path, ancestorsEnabled); continue }
                    guard role == kAXMenuItemRole || role == kAXMenuBarItemRole else { continue }
                    let title = try title(child)
                    guard !title.isEmpty else { continue }
                    let descendants = try children(child)
                    let isParent = !descendants.isEmpty
                    let ownEnabled = optional(child, kAXEnabledAttribute) as? Bool
                    let enabled: Bool? = ancestorsEnabled == false || ownEnabled == false ? false
                        : (ancestorsEnabled == true && ownEnabled == true ? true : nil)
                    let next = path + [title]
                    items.append(.init(path: next, isEnabled: enabled, hasSubmenu: isParent,
                                       mark: optional(child, kAXMenuItemMarkCharAttribute) as? String,
                                       shortcut: shortcut(child)))
                    if isParent { walk(child, next, enabled) }
                }
            } catch { issues.append(String(describing: error)) }
        }
        walk(bar, [], true)
        return MenuCatalog(items: items, isComplete: issues.isEmpty, issues: Array(Set(issues)).sorted())
    }

    /// Calls validation on the final native boundary, after path lookup and before the single press.
    /// Validation must attest the focused AX window; it must never focus or raise it to force a match.
    public func invoke(path: [String], processID: pid_t,
                       validate: (AXUIElement) throws -> Void) throws -> MenuDelivery {
        try invokeNative(path: path, processID: processID) { application in
            try validate(try element(application, kAXFocusedWindowAttribute))
        }
    }

    /// Opens one explicit recent document without requiring a document window to exist first.
    /// The host must hold exclusive automation ownership and validate cancellation at this boundary.
    public func openRecent(path: [String], processID: pid_t, validate: () throws -> Void) throws -> MenuDelivery {
        _ = try RecentDocument(path: path)
        return try invokeNative(path: path, processID: processID) { application in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else {
                throw MenuFailure("Cannot rule out a blocking application dialog.")
            }
            for window in windows {
                guard optional(window, kAXModalAttribute) as? Bool == false,
                      try !children(window).contains(where: { try string($0, kAXRoleAttribute) == kAXSheetRole }) else {
                    throw MenuFailure("An application dialog is blocking document opening, or its state is unknown.")
                }
            }
            try validate()
        }
    }

    private func invokeNative(path: [String], processID: pid_t,
                              validate: (AXUIElement) throws -> Void) throws -> MenuDelivery {
        guard (2...8).contains(path.count), path.allSatisfy({ !MenuCatalog.key($0).isEmpty }) else {
            throw MenuFailure("A menu command needs a full path of 2...8 nonempty components.")
        }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var node = try element(application, kAXMenuBarAttribute)
        for (index, title) in path.enumerated() {
            var siblings = try children(node)
            if siblings.count == 1, let container = siblings.first,
               try string(container, kAXRoleAttribute) == kAXMenuRole {
                siblings = try children(container)
            }
            let matches = try siblings.filter { try MenuCatalog.key(self.title($0)) == MenuCatalog.key(title) }
            guard matches.count == 1, let match = matches.first else {
                throw MenuFailure("Menu component '\(title)' is missing or ambiguous.")
            }
            if index == 0, let first = siblings.first, CFEqual(match, first) {
                throw MenuFailure("The Apple menu belongs to the system, not to the application.")
            }
            let role = try string(match, kAXRoleAttribute)
            guard role == kAXMenuItemRole || role == kAXMenuBarItemRole else {
                throw MenuFailure("The path does not identify a native menu item.")
            }
            guard optional(match, kAXEnabledAttribute) as? Bool == true else {
                throw MenuFailure("Menu component '\(title)' is disabled or its availability is unknown.")
            }
            node = match
            if index == path.count - 1 {
                guard role == kAXMenuItemRole, try children(node).isEmpty else {
                    throw MenuFailure("The path names a submenu, not an executable command.")
                }
            }
        }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(node, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true else {
            throw MenuFailure("The menu item does not expose AXPress.")
        }
        if let character = optional(node, kAXMenuItemCmdCharAttribute) as? String,
           character.lowercased() == "q",
           let modifiers = optional(node, kAXMenuItemCmdModifiersAttribute) as? Int, modifiers & 8 == 0 {
            throw MenuFailure("Commands bound to Command-Q are refused.")
        }
        if let character = optional(node, kAXMenuItemCmdCharAttribute) as? String,
           character.lowercased() == "h",
           let modifiers = optional(node, kAXMenuItemCmdModifiersAttribute) as? Int, modifiers & 8 == 0 {
            throw MenuFailure("Commands that hide the application are refused.")
        }
        try Task.checkCancellation()
        try validate(application)
        let result = AXUIElementPerformAction(node, kAXPressAction as CFString)
        return result == .success ? .requested : .uncertain("AXPress returned \(result.rawValue); do not replay.")
    }

    private func children(_ node: AXUIElement) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value)
        if result == .noValue || result == .attributeUnsupported { return [] }
        guard result == .success, let children = value as? [AXUIElement] else {
            throw MenuFailure("Menu children unreadable (AX \(result.rawValue)).")
        }
        return children
    }

    private func element(_ node: AXUIElement, _ attribute: String) throws -> AXUIElement {
        guard let value = optional(node, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw MenuFailure("Native menu context unavailable: \(attribute). Check Accessibility access.")
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Separators expose no title. A failed read is distinct from an absent title.
    private func title(_ node: AXUIElement) throws -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(node, kAXTitleAttribute as CFString, &value)
        if result == .noValue || result == .attributeUnsupported { return "" }
        guard result == .success, let title = value as? String else {
            throw MenuFailure("Menu title unreadable (AX \(result.rawValue)).")
        }
        return title
    }

    private func string(_ node: AXUIElement, _ attribute: String) throws -> String {
        guard let value = optional(node, attribute) as? String else {
            throw MenuFailure("Menu attribute unreadable: \(attribute).")
        }
        return value
    }

    private func optional(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func shortcut(_ node: AXUIElement) -> String? {
        guard let character = optional(node, kAXMenuItemCmdCharAttribute) as? String, !character.isEmpty else { return nil }
        guard let modifiers = optional(node, kAXMenuItemCmdModifiersAttribute) as? Int else { return character }
        var result = modifiers & 8 == 0 ? "cmd+" : ""
        if modifiers & 1 != 0 { result += "shift+" }
        if modifiers & 2 != 0 { result += "opt+" }
        if modifiers & 4 != 0 { result += "ctrl+" }
        return result + character
    }
}

import ApplicationServices
import Foundation
import AccessibilityFacts
import PerceptionCore

/// DropdownOpening requests the native show-menu action on one uniquely named control in one window.
/// Some applications retain the AX request until their menu closes. A timeout is therefore an
/// uncertain delivery, never a reason to repeat it; the caller must observe the menu through WindowServer.
@MainActor
public enum DropdownOpening {

    /// Window binds native dropdown lookup to an attested capture recipient and its current frame.
    /// The composition layer supplies the native ID resolver; titles and focus are not fallbacks.
    public struct Window {
        let processID: pid_t
        let number: Int
        let frame: CGRect
        let resolveNumber: (AXUIElement) -> Int?

        public init(
            processID: pid_t,
            number: Int,
            frame: CGRect,
            resolveNumber: @escaping (AXUIElement) -> Int?
        ) {
            self.processID = processID
            self.number = number
            self.frame = frame
            self.resolveNumber = resolveNumber
        }
    }

    public static func select(item: String, in menuFrame: CGRect, processID: pid_t) throws {
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 0.2)
        let selected = nativeMenuItem(named: item, in: menuFrame, under: root,
                                      reader: LiveAccessibilityReader())
        guard let selected else {
            throw Failure.controlNotUnique
        }
        var actions: CFArray?
        AXUIElementCopyActionNames(selected, &actions)
        guard (actions as? [String] ?? []).contains(kAXPressAction) else { throw Failure.pressUnsupported }
        try Task.checkCancellation()
        let result = AXUIElementPerformAction(selected, kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else { throw Failure.actionRefused(result.rawValue) }
    }

    /// Resolves one painted native menu item. Chromium can expose the same option under
    /// its web area and in an AppKit popup; only the latter is a native action recipient.
    /// Two native matches remain ambiguous, and lookup never dispatches an action. Titles compare
    /// by `LabelText.menuTitleKey`: case, bidi controls, typographic quotes and an ellipsis aside.
    static func nativeMenuItem<Reader: AccessibilityTreeReading>(
        named item: String, in menuFrame: CGRect, under root: Reader.Node, reader: Reader
    ) -> Reader.Node? {
        var painted: [(node: Reader.Node, title: String)] = []
        func visit(_ node: Reader.Node, _ depth: Int) {
            // CEF's native popup rows sit at depth twelve under its AppKit wrappers.
            // Match the bounded control search without traversing web option mirrors.
            guard depth < 16 else { return }
            let role = reader.role(node) ?? ""
            guard role != "AXWebArea" else { return }
            if role == kAXMenuItemRole,
               let frame = reader.frame(node), frame.width > 0, frame.height > 0,
               menuFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                painted.append((node, reader.title(node) ?? ""))
            }
            for child in reader.children(node) { visit(child, depth + 1) }
        }
        visit(root, 0)
        guard let index = LabelText.menuItemMatch(item, in: painted.map(\.title)),
              reader.isEnabled(painted[index].node) == true
        else { return nil }
        return painted[index].node
    }

    public enum Failure: Error, CustomStringConvertible {
        case windowNotUnique
        case controlMissing
        case controlNotUnique
        case showMenuUnsupported
        case pressUnsupported
        case actionRefused(Int32)

        public var description: String {
            switch self {
                case .windowNotUnique: "the requested accessibility window is missing or ambiguous"
                case .controlMissing: "no native dropdown exposes the requested label or value"
                case .controlNotUnique: "the native dropdown or menu item could not be uniquely identified"
                case .showMenuUnsupported: "the dropdown does not expose a native opening action"
                case .pressUnsupported: "the menu item does not expose a native Press action"
                case .actionRefused(let code): "the application refused the accessibility action (\(code))"
            }
        }
    }

    /// Probes before posting anything. A missing native control or opening action allows a
    /// pixel-resolved opener; ambiguous controls and unreadable windows must still refuse.
    public static func canShow(control label: String, window title: String, processID: pid_t) throws -> Bool {
        let control: AXUIElement
        do { control = try uniqueControl(label: label, window: title, processID: processID) }
        catch Failure.controlMissing { return false }
        var actions: CFArray?
        AXUIElementCopyActionNames(control, &actions)
        return openingAction(in: actions as? [String] ?? []) != nil
    }

    public static func canShow(control label: String, in window: Window) throws -> Bool {
        let control: AXUIElement
        do { control = try uniqueControl(label: label, in: window) }
        catch Failure.controlMissing { return false }
        var actions: CFArray?
        AXUIElementCopyActionNames(control, &actions)
        return openingAction(in: actions as? [String] ?? []) != nil
    }

    public static func show(control label: String, window title: String, processID: pid_t) throws {
        let control = try uniqueControl(label: label, window: title, processID: processID)
        try show(control)
    }

    public static func show(control label: String, in window: Window) throws {
        try show(uniqueControl(label: label, in: window))
    }

    private static func show(_ control: AXUIElement) throws {
        var actions: CFArray?
        AXUIElementCopyActionNames(control, &actions)
        guard let action = openingAction(in: actions as? [String] ?? []) else { throw Failure.showMenuUnsupported }
        AXUIElementSetMessagingTimeout(control, 0.2)
        let result = AXUIElementPerformAction(control, action as CFString)
        guard result == .success || result == .cannotComplete else { throw Failure.actionRefused(result.rawValue) }
    }

    /// Prefers the dropdown's primary action. Show Menu can open a control's contextual menu.
    /// A Show Menu-only control retains its existing opening route; no action is replayed.
    static func openingAction(in actions: [String]) -> String? {
        if actions.contains(kAXPressAction) { return kAXPressAction }
        return actions.contains(kAXShowMenuAction) ? kAXShowMenuAction : nil
    }

    /// Reads the bounds of one exact native dropdown, without opening it. The caller must reject
    /// stale geometry and confirm the requested label in captured pixels before using the result.
    public static func frame(control label: String, window title: String, processID: pid_t) throws -> CGRect? {
        let control = try uniqueControl(label: label, window: title, processID: processID)
        return LiveAccessibilityReader().frame(control)
    }

    public static func frame(control label: String, in window: Window) throws -> CGRect? {
        LiveAccessibilityReader().frame(try uniqueControl(label: label, in: window))
    }

    /// Reads the native value of one exact dropdown, without opening it.
    public static func value(control label: String, in window: Window) throws -> String? {
        LiveAccessibilityReader().value(try uniqueControl(label: label, in: window))
    }

    private static func uniqueControl(label: String, in scope: Window) throws -> AXUIElement {
        let reader = LiveAccessibilityReader()
        let application = reader.application(processID: scope.processID)
        reader.setMessagingTimeout(application, seconds: 0.2)
        guard let window = reader.window(
            of: application,
            matching: scope.frame,
            isCapturedWindow: { scope.resolveNumber($0) == scope.number }
        ) else { throw Failure.windowNotUnique }
        return try uniqueControl(label: label, under: window)
    }

    private static func uniqueControl(label: String, window title: String, processID: pid_t) throws -> AXUIElement {
        func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            AXUIElementCopyAttributeValue(node, attribute as CFString, &result)
            return result
        }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let windows = (value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            (value($0, kAXTitleAttribute) as? String) == title
        }
        guard windows.count == 1 else { throw Failure.windowNotUnique }
        return try uniqueControl(label: label, under: windows[0])
    }

    private static func uniqueControl(label: String, under window: AXUIElement) throws -> AXUIElement {
        func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            AXUIElementCopyAttributeValue(node, attribute as CFString, &result)
            return result
        }
        var controls: [AXUIElement] = []
        func visit(_ node: AXUIElement, _ depth: Int) {
            guard depth < 16 else { return }
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            // A menu button opens its menu by AXPress too: a file panel's view mode is one.
            if [kAXPopUpButtonRole, kAXComboBoxRole, kAXMenuButtonRole].contains(role),
               (value(node, kAXTitleAttribute) as? String)?.caseInsensitiveCompare(label) == .orderedSame
                || (value(node, kAXValueAttribute) as? String)?.caseInsensitiveCompare(label) == .orderedSame
                || (value(node, kAXDescriptionAttribute) as? String)?.caseInsensitiveCompare(label) == .orderedSame {
                controls.append(node)
                return
            }
            for child in value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
        }
        visit(window, 0)
        guard !controls.isEmpty else { throw Failure.controlMissing }
        guard controls.count == 1 else { throw Failure.controlNotUnique }
        return controls[0]
    }
}

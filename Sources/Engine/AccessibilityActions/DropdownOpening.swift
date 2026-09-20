import ApplicationServices
import Foundation
import AccessibilityFacts

/// DropdownOpening requests the native show-menu action on one uniquely named control in one window.
/// Some applications retain the AX request until their menu closes. A timeout is therefore an
/// uncertain delivery, never a reason to repeat it; the caller must observe the menu through WindowServer.
@MainActor
public enum DropdownOpening {

    public static func select(item: String, in menuFrame: CGRect, processID: pid_t) throws {
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 0.2)
        func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            AXUIElementCopyAttributeValue(node, attribute as CFString, &result)
            return result
        }
        var matches: [AXUIElement] = []
        func visit(_ node: AXUIElement, _ depth: Int) {
            guard depth < 12 else { return }
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            let title = value(node, kAXTitleAttribute) as? String ?? ""
            if role == kAXMenuItemRole, title.caseInsensitiveCompare(item) == .orderedSame {
                var position = CGPoint.zero
                var size = CGSize.zero
                if let origin = value(node, kAXPositionAttribute), CFGetTypeID(origin) == AXValueGetTypeID(),
                   let dimensions = value(node, kAXSizeAttribute), CFGetTypeID(dimensions) == AXValueGetTypeID(),
                   AXValueGetValue(origin as! AXValue, .cgPoint, &position),
                   AXValueGetValue(dimensions as! AXValue, .cgSize, &size),
                   size.width > 0, size.height > 0,
                   menuFrame.contains(CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)) {
                    matches.append(node)
                }
            }
            for child in value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
        }
        visit(root, 0)
        guard matches.count == 1 else { throw Failure.controlNotUnique }
        var actions: CFArray?
        AXUIElementCopyActionNames(matches[0], &actions)
        guard (actions as? [String] ?? []).contains(kAXPressAction) else { throw Failure.pressUnsupported }
        try Task.checkCancellation()
        let result = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else { throw Failure.actionRefused(result.rawValue) }
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
                case .showMenuUnsupported: "the dropdown does not expose a native Show Menu action"
                case .pressUnsupported: "the menu item does not expose a native Press action"
                case .actionRefused(let code): "the application refused the accessibility action (\(code))"
            }
        }
    }

    /// Probes before posting anything. A missing native control or Show Menu action allows a
    /// pixel-resolved opener; ambiguous controls and unreadable windows must still refuse.
    public static func canShow(control label: String, window title: String, processID: pid_t) throws -> Bool {
        let control: AXUIElement
        do { control = try uniqueControl(label: label, window: title, processID: processID) }
        catch Failure.controlMissing { return false }
        var actions: CFArray?
        AXUIElementCopyActionNames(control, &actions)
        return (actions as? [String] ?? []).contains(kAXShowMenuAction)
    }

    public static func show(control label: String, window title: String, processID: pid_t) throws {
        let control = try uniqueControl(label: label, window: title, processID: processID)
        var actions: CFArray?
        AXUIElementCopyActionNames(control, &actions)
        guard (actions as? [String] ?? []).contains(kAXShowMenuAction) else { throw Failure.showMenuUnsupported }
        AXUIElementSetMessagingTimeout(control, 0.2)
        let result = AXUIElementPerformAction(control, kAXShowMenuAction as CFString)
        guard result == .success || result == .cannotComplete else { throw Failure.actionRefused(result.rawValue) }
    }

    /// Reads the bounds of one exact native dropdown, without opening it. The caller must reject
    /// stale geometry and confirm the requested label in captured pixels before using the result.
    public static func frame(control label: String, window title: String, processID: pid_t) throws -> CGRect? {
        let control = try uniqueControl(label: label, window: title, processID: processID)
        return LiveAccessibilityReader().frame(control)
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
        var controls: [AXUIElement] = []
        func visit(_ node: AXUIElement, _ depth: Int) {
            guard depth < 10 else { return }
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            if [kAXPopUpButtonRole, kAXComboBoxRole].contains(role),
               (value(node, kAXTitleAttribute) as? String)?.caseInsensitiveCompare(label) == .orderedSame
                || (value(node, kAXValueAttribute) as? String)?.caseInsensitiveCompare(label) == .orderedSame {
                controls.append(node)
                return
            }
            for child in value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
        }
        visit(windows[0], 0)
        guard !controls.isEmpty else { throw Failure.controlMissing }
        guard controls.count == 1 else { throw Failure.controlNotUnique }
        return controls[0]
    }
}

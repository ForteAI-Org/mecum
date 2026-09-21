import Foundation
import CoreGraphics
import ApplicationServices

/// Live ``AXTreeReading`` over the ApplicationServices `AXUIElement` C-API.
///
/// Stateless (→ `Sendable`). **Invariant: all methods must be called on the main actor.** The methods
/// aren't themselves actor-isolated (so the generic algorithms can stay generic), but they return
/// non-`Sendable` `AXUIElement`s; ``AXEngine`` (which is `@MainActor`) is the only intended caller.
/// A per-app messaging timeout guards against pathological hangs on deep/slow trees (Pro Tools).
public struct LiveAXReader: AXTreeReading, Sendable {
    public init() {}

    // MARK: Attribute reads

    /// Copy an attribute value. A `.cannotComplete` (messaging timeout) is *transient* and retried
    /// once — distinct from a genuinely-absent attribute. If it still times out we return `nil`; the
    /// residual "timeout looks like absent" risk on truly pathological trees is bounded by the per-app
    /// messaging timeout and revisited in the Pro-Tools hardening pass.
    private func copyAttr(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        for _ in 0..<2 {
            var ref: CFTypeRef?
            switch AXUIElementCopyAttributeValue(e, attr as CFString, &ref) {
            case .success: return ref
            case .cannotComplete: continue          // transient timeout → retry once
            default: return nil                      // genuinely absent / unsupported / no value
            }
        }
        return nil
    }

    public func role(_ e: AXUIElement) -> String? { copyAttr(e, kAXRoleAttribute as String) as? String }
    public func title(_ e: AXUIElement) -> String? { copyAttr(e, kAXTitleAttribute as String) as? String }
    public func descriptionText(_ e: AXUIElement) -> String? { copyAttr(e, kAXDescriptionAttribute as String) as? String }
    public func identifier(_ e: AXUIElement) -> String? { copyAttr(e, kAXIdentifierAttribute as String) as? String }
    public func enabled(_ e: AXUIElement) -> Bool? { copyAttr(e, kAXEnabledAttribute as String) as? Bool }
    /// The element's value as a string when it is one (text fields, static text, steppers) — nil otherwise.
    public func value(_ e: AXUIElement) -> String? { copyAttr(e, kAXValueAttribute as String) as? String }
    /// The element's NUMERIC value (`kAXValueAttribute` as a number) — a toggle/checkbox/radio reports
    /// 0 = off, 1 = on, 2 = mixed. nil if absent / not numeric (e.g. an AX-less control).
    public func numericValue(_ e: AXUIElement) -> Int? { (copyAttr(e, kAXValueAttribute as String) as? NSNumber)?.intValue }
    /// Menu-item read-only context: the checkmark/state glyph and the keyboard-shortcut key, if any.
    public func menuItemMarkChar(_ e: AXUIElement) -> String? { copyAttr(e, kAXMenuItemMarkCharAttribute as String) as? String }
    public func menuItemCmdChar(_ e: AXUIElement) -> String? { copyAttr(e, kAXMenuItemCmdCharAttribute as String) as? String }
    /// Recovery only: cancel/dismiss a shown menu without selecting anything (kAXCancelAction).
    public func performCancel(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXCancelAction as CFString) == .success }

    public func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public func frame(_ e: AXUIElement) -> CGRect? {
        guard let posV = axValue(copyAttr(e, kAXPositionAttribute as String)),
              let sizeV = axValue(copyAttr(e, kAXSizeAttribute as String)) else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posV, .cgPoint, &pt), AXValueGetValue(sizeV, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    public func children(_ e: AXUIElement) -> [AXUIElement] {
        (copyAttr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    // MARK: Scroll support (Phase 1) — generic attribute element read + numeric value read/write

    /// The child element under `attribute` (e.g. a scroll area's `AXVerticalScrollBar`).
    public func attributeElement(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        element(copyAttr(e, attribute))
    }
    /// A numeric attribute (e.g. a scroll bar's `AXValue`, 0…1).
    public func doubleAttr(_ e: AXUIElement, _ attribute: String) -> Double? {
        (copyAttr(e, attribute) as? NSNumber)?.doubleValue
    }
    /// Set a numeric attribute (e.g. drive a scroll bar's `AXValue`). Returns whether the app accepted it.
    @discardableResult
    public func setDoubleAttr(_ e: AXUIElement, _ attribute: String, _ value: Double) -> Bool {
        AXUIElementSetAttributeValue(e, attribute as CFString, NSNumber(value: value)) == .success
    }

    public func parent(_ e: AXUIElement) -> AXUIElement? {
        element(copyAttr(e, kAXParentAttribute as String))
    }

    public func isEqual(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    // MARK: CF type coercion

    private func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func axValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }

    // MARK: Live-only operations (not part of the tree-reading protocol)

    /// Hit-test a global (top-left, points) screen point against the system-wide AX tree.
    public func hitTest(globalPoint p: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        return AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &element) == .success ? element : nil
    }

    public func pid(of e: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(e, &pid) == .success ? pid : nil
    }

    /// Role of the system-wide FOCUSED element (where typed keys will land) — nil when unreadable
    /// (zero-AX apps). The type verb's secure-field gate: "AXSecureTextField" must refuse.
    public func focusedElementRole() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }

    public func applicationElement(pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    /// The element's containing window, read directly via `kAXWindowAttribute` (every AX element
    /// exposes it), falling back to `kAXTopLevelUIElementAttribute`. Far more robust than walking
    /// ancestors and hoping the top hop is an `AXWindow` (floating panels / deep trees break that).
    public func window(of e: AXUIElement) -> AXUIElement? {
        element(copyAttr(e, kAXWindowAttribute as String))
            ?? element(copyAttr(e, kAXTopLevelUIElementAttribute as String))
    }

    /// The app's windows. Read via `kAXWindowsAttribute` (the canonical source); falls back to the
    /// app element's children when an app exposes windows only there. Application elements don't
    /// reliably list their windows under `kAXChildrenAttribute`, so replay must use this for the
    /// app → window hop rather than the generic children descent.
    public func windows(of app: AXUIElement) -> [AXUIElement] {
        let viaWindows = (copyAttr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        return viaWindows.isEmpty ? children(app) : viaWindows
    }

    /// Cap each AX IPC round-trip so a pathological `kAXChildrenAttribute` read can't hang the caller.
    public func setMessagingTimeout(_ e: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(e, seconds)
    }

    @discardableResult
    public func performPress(_ e: AXUIElement) -> Bool {
        AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    // MARK: window control (minimize / fullscreen / frame)

    public func boolAttr(_ e: AXUIElement, _ attribute: String) -> Bool? {
        copyAttr(e, attribute) as? Bool
    }

    @discardableResult
    public func setBoolAttr(_ e: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(e, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    /// Set a STRING attribute (kAXValue on a text field). Standard AppKit fields honor it — the
    /// invisible, instant way to fill a field; custom-drawn fields (Pro Tools dialogs) refuse, and the
    /// caller falls back to click+keyboard. Always verify with a read-back.
    @discardableResult
    public func setStringAttr(_ e: AXUIElement, _ attribute: String, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(e, attribute as CFString, value as CFString) == .success
    }

    /// Set a window's frame (AX global, top-left origin). Position and size are SEPARATE AX attributes
    /// that apps clamp against each other, so the order is position → size → position again: sizing first
    /// can grow the window past a screen edge and make the app shove it somewhere else entirely.
    @discardableResult
    public func setFrame(_ e: AXUIElement, _ r: CGRect) -> Bool {
        var pt = r.origin
        var sz = r.size
        guard let pv = AXValueCreate(.cgPoint, &pt), let sv = AXValueCreate(.cgSize, &sz) else { return false }
        let posOK = AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, pv) == .success
        let sizeOK = AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sv) == .success
        _ = AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, pv)
        return posOK && sizeOK
    }
}

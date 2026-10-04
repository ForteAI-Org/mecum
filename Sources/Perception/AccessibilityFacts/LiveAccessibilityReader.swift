//
//  LiveAccessibilityReader.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import PerceptionCore

/// LiveAccessibilityReader fills `AccessibilityTreeReading` over the system's `AXUIElement` handles.
///
/// Stateless, and every read happens on the main actor: the C API is not safe to call elsewhere, and
/// the handles it returns are not Sendable. A `.cannotComplete` answer (a messaging timeout) is
/// transient and retried once; anything else is a genuine absence and reads as nil. The per-app
/// messaging timeout bounds a pathological tree so one slow app cannot hang the caller.
@MainActor
public struct LiveAccessibilityReader: AccessibilityTreeReading {

    public typealias Node = AXUIElement

    public init() {}

    public nonisolated func role(_ node: AXUIElement) -> String? { string(node, kAXRoleAttribute) }
    public nonisolated func subrole(_ node: AXUIElement) -> String? { string(node, kAXSubroleAttribute) }
    public nonisolated func title(_ node: AXUIElement) -> String? { string(node, kAXTitleAttribute) }
    public nonisolated func descriptionText(_ node: AXUIElement) -> String? { string(node, kAXDescriptionAttribute) }
    public nonisolated func identifier(_ node: AXUIElement) -> String? { string(node, kAXIdentifierAttribute) }
    public nonisolated func value(_ node: AXUIElement) -> String? { string(node, kAXValueAttribute) }

    public nonisolated func numericValue(_ node: AXUIElement) -> Int? {
        (attribute(node, kAXValueAttribute) as? NSNumber)?.intValue
    }

    public nonisolated func isEnabled(_ node: AXUIElement) -> Bool? { attribute(node, kAXEnabledAttribute) as? Bool }

    public nonisolated func actions(_ node: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public nonisolated func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = axValue(attribute(node, kAXPositionAttribute)),
              let size = axValue(attribute(node, kAXSizeAttribute)) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    public nonisolated func children(_ node: AXUIElement) -> [AXUIElement] {
        (attribute(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    // MARK: Application and windows

    public nonisolated func application(processID: pid_t) -> AXUIElement { AXUIElementCreateApplication(processID) }

    /// The focused window, else the first window the app lists, else nil for an app with no tree.
    public nonisolated func mainWindow(of application: AXUIElement) -> AXUIElement? {
        element(attribute(application, kAXFocusedWindowAttribute))
            ?? windows(of: application).first(where: { role($0) == "AXWindow" })
    }

    /// The app's windows from `kAXWindowsAttribute`, falling back to the app element's children for
    /// the apps that list them only there.
    public nonisolated func windows(of application: AXUIElement) -> [AXUIElement] {
        let listed = (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return listed.isEmpty ? children(application) : listed
    }

    /// Selects the captured window, including a sheet exposed as a child of another window.
    /// Focus is not a geometry fallback: a background capture may name a different surface.
    public nonisolated func window(
        of application: AXUIElement, matching frame: CGRect,
        isCapturedWindow: (AXUIElement) -> Bool = { _ in true }
    ) -> AXUIElement? {
        let listed = windows(of: application)
        var candidates = listed
        for window in listed {
            candidates.append(contentsOf: children(window).filter { role($0) == "AXSheet" })
        }
        return AccessibilityWindowMatching.window(
            among: candidates, capturedFrame: frame, reader: self, isCapturedWindow: isCapturedWindow
        )
    }

    /// Caps each message to this element's process so a hung app bounds the cost of a read.
    public nonisolated func setMessagingTimeout(_ node: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(node, seconds)
    }

    // MARK: Attribute reads

    private nonisolated func string(_ node: AXUIElement, _ name: String) -> String? { attribute(node, name) as? String }

    private nonisolated func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        for _ in 0..<2 {
            var reference: CFTypeRef?
            switch AXUIElementCopyAttributeValue(node, name as CFString, &reference) {
                case .success       : return reference
                case .cannotComplete: continue
                default             : return nil
            }
        }
        return nil
    }

    private nonisolated func element(_ reference: CFTypeRef?) -> AXUIElement? {
        guard let reference, CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
        // The type id check above is the precondition; a Swift cast cannot see through a CF type here.
        return unsafeDowncast(reference, to: AXUIElement.self)
    }

    private nonisolated func axValue(_ reference: CFTypeRef?) -> AXValue? {
        guard let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        // Same precondition as `element`: the CF type id was checked one line up.
        return unsafeDowncast(reference, to: AXValue.self)
    }
}

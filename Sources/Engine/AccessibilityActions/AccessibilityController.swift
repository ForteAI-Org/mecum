//
//  AccessibilityController.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AccessibilityFacts
import ApplicationServices
import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// AccessibilityController fills `ControlPressing` with the live accessibility tree: it finds a
/// combo box or pop-up button by its value or title and presses it, reads the value of the one
/// control whose value is among a set of labels, reads a toggle's state under a point, and reads
/// the value of the text field that holds the application's focus.
///
/// Every read and press hops to the main actor, where the C API is safe. Geometry is used only for
/// the hit test under a point, never to relate a control to a pop-up: after a window-server move
/// the tree's frames are stale, and matching by value is what stays true.
public struct AccessibilityController: ControlPressing {

    private static let controlRoles: Set<String> = ["AXComboBox", "AXPopUpButton"]
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    public init() {}

    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        let want = LabelText.normalize(label)
        guard !want.isEmpty else { return false }
        return await MainActor.run {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: 1)
            guard let control = Self.firstControl(in: reader.windows(of: application), reader: reader, where: { node in
                LabelText.normalize(reader.value(node) ?? "") == want
                    || LabelText.normalize(reader.title(node) ?? "") == want
            }) else { return false }
            return AXUIElementPerformAction(control, kAXPressAction as CFString) == .success
        }
    }

    public func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
        guard !labels.isEmpty else { return nil }
        return await MainActor.run {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: 1)
            var matches: [String] = []
            Self.walk(reader.windows(of: application), reader: reader) { node in
                guard Self.controlRoles.contains(reader.role(node) ?? ""), let value = reader.value(node) else {
                    return false
                }
                if labels.contains(LabelText.normalize(value)) { matches.append(value) }
                return false
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    public func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? {
        await MainActor.run {
            let reader = LiveAccessibilityReader()
            var element: AXUIElement?
            let system = AXUIElementCreateSystemWide()
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
                  let element else { return nil }
            switch reader.numericValue(element) {
                case 0 : return .off
                case 1 : return .on
                case 2 : return .mixed
                default: return nil
            }
        }
    }

    public func focusedFieldValue(in processID: pid_t) async -> String? {
        await MainActor.run {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: 1)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
                    == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            // The type id was checked one line up; a Swift cast cannot see through a CF type here.
            let field = unsafeDowncast(focused, to: AXUIElement.self)
            guard Self.fieldRoles.contains(reader.role(field) ?? "") else { return nil }
            return reader.value(field)
        }
    }

    // MARK: Walk

    @MainActor
    private static func firstControl(
        in roots: [AXUIElement],
        reader  : LiveAccessibilityReader,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var found: AXUIElement?
        walk(roots, reader: reader) { node in
            guard controlRoles.contains(reader.role(node) ?? ""), predicate(node) else { return false }
            found = node
            return true
        }
        return found
    }

    /// Visits every node under the roots, depth first to ten levels, until `visit` returns true.
    @MainActor
    private static func walk(_ roots: [AXUIElement], reader: LiveAccessibilityReader, visit: (AXUIElement) -> Bool) {
        var stop = false
        func descend(_ node: AXUIElement, _ depth: Int) {
            guard !stop, depth <= 10 else { return }
            if visit(node) { stop = true; return }
            for child in reader.children(node) { descend(child, depth + 1) }
        }
        for root in roots { descend(root, 0) }
    }
}

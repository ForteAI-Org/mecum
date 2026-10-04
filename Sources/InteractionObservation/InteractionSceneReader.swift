import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import InteractionListener
import Perception
import PerceptionCore
import ScreenCapture

/// InteractionSceneReader reads the exact surface recorded by the listener, including popup windows.
/// The caller supplies the production pipeline. No memory, agent, Seat or application UI is constructed.
public struct InteractionSceneReader: Sendable {
    private let pipeline: ScenePipeline
    private let capturer: StillCapturer

    public init(pipeline: ScenePipeline) {
        self.pipeline = pipeline
        capturer = StillCapturer()
    }

    public func scene(window: InteractionWindow, bundleID: String, appName: String) async throws -> SceneSnapshot {
        let image = try await capturer.captureWindow(number: window.number, frame: window.frame)
        return try await pipeline.perceive(image, of: ScenePipeline.Window(
            bundleID: bundleID, appName: appName, title: window.title ?? "",
            processID: window.processID, frame: window.frame, windowNumber: window.number
        ))
    }

    /// Reports AX in the routed application at the current point, explicitly after input.
    /// App-scoped hit testing avoids unrelated overlays; a process mismatch still rejects the hit.
    @MainActor
    public static func accessibility(at point: CGPoint, processID: Int32) -> AccessibilityPointResult {
        guard AXIsProcessTrusted() else { return AccessibilityPointResult(status: "permission_missing") }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element)
        guard result == .success, let element else {
            return AccessibilityPointResult(status: "unavailable(\(result.rawValue))")
        }
        AXUIElementSetMessagingTimeout(element, 0.1)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == processID else {
            return AccessibilityPointResult(status: "different_process", processID: owner)
        }
        // The deadline bounds traversal; each AX message also has a short timeout.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        func attribute(_ node: AXUIElement, _ key: CFString) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(node, 0.02)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, key, &value) == .success else { return nil }
            return value
        }
        func facts(_ node: AXUIElement) -> InteractionAXLabel.Facts {
            let role = attribute(node, kAXRoleAttribute as CFString) as? String
            let title = attribute(node, kAXTitleAttribute as CFString) as? String
            let description = attribute(node, kAXDescriptionAttribute as CFString) as? String
            let filename = attribute(node, kAXFilenameAttribute as CFString) as? String
            var displayValue: String?
            let subrole = attribute(node, kAXSubroleAttribute as CFString) as? String
            if subrole != "AXSecureTextField", ProcessInfo.processInfo.systemUptime < deadline {
                var settable = DarwinBoolean(true)
                let readOnlyField = role == "AXTextField"
                    && AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable) == .success
                    && !settable.boolValue
                if InteractionAXLabel.allowsDisplayValue(role: role, subrole: subrole,
                                                        valueIsSettable: readOnlyField ? false : nil) {
                    displayValue = attribute(node, kAXValueAttribute as CFString) as? String
                }
            }
            return .init(role: role, title: title, description: description, displayValue: displayValue,
                         filename: filename.map { ($0 as NSString).lastPathComponent })
        }
        let role = attribute(element, kAXRoleAttribute as CFString) as? String
        let name = InteractionAXLabel.resolve(element, facts: facts, children: { node in
            guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, 12, &values) == .success
            else { return [] }
            return (values as? [AXUIElement]) ?? []
        })
        return AccessibilityPointResult(status: "read_after_event", role: role, label: name?.label,
                                        processID: owner, labelSource: name?.source)
    }
}

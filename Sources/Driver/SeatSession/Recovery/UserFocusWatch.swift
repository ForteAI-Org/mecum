import AppKit
import CoreGraphics
import Darwin
import Dispatch
import Foundation

/// Read-only notifications. No activation, AX action, synthetic click or key.
/// Focused-window changes keep the cached destination current within one app.
final class UserFocusWatch {
    private var activation: (any NSObjectProtocol)?
    private var input: Any?
    private var axObserver: AXObserver?
    private var axApplication: AXUIElement?
    private var watchedProcessID: Int32?
    private let isUserApplication: (Int32) -> Bool
    private let changed: (Int32, UInt64) -> Void
    private let windowChanged: () -> Void
    private static var lastSwitchIntent: UInt64 = 0

    static var hasRecentSwitchIntent: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return lastSwitchIntent > 0 && now &- lastSwitchIntent < 350_000_000
    }

    init(changed: @escaping (Int32, UInt64) -> Void, windowChanged: @escaping () -> Void,
         isUserApplication: @escaping (Int32) -> Bool) {
        self.changed = changed
        self.windowChanged = windowChanged
        self.isUserApplication = isUserApplication
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let received = DispatchTime.now().uptimeNanoseconds
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            // Preserve synchronous delivery on main; timestamp before any hop.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.activationReceived(pid, at: received) }
            } else {
                Task { @MainActor [weak self] in self?.activationReceived(pid, at: received) }
            }
        }
        input = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
            // Ordinary typing does not suppress recovery. Clicks, Command-Tab
            // and Control-arrow can deliberately activate an adopted app.
            let keySwitch = event.type == .keyDown && (
                ([48, 50].contains(event.keyCode) && event.modifierFlags.contains(.command)) ||
                ([123, 124, 125, 126].contains(event.keyCode) && event.modifierFlags.contains(.control))
            )
            if event.type != .keyDown || keySwitch {
                Self.lastSwitchIntent = DispatchTime.now().uptimeNanoseconds
            }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { watchWindows(of: pid) }
    }

    private func activationReceived(_ pid: Int32, at received: UInt64) {
        guard activation != nil else { return }
        changed(pid, received)
        watchWindows(of: pid)
    }

    private func watchWindows(of pid: Int32) {
        // Keep the user's AX observer during a transient target activation.
        // Subscribing to the busy target's AX server here can block the main
        // actor precisely while focus restoration needs its notifications.
        guard isUserApplication(pid), watchedProcessID != pid else { return }
        removeWindowWatch()
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<UserFocusWatch>.fromOpaque(context).takeUnretainedValue().windowChanged()
            }
        }, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        axObserver = observer
        axApplication = app
        watchedProcessID = pid
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeWindowWatch() {
        if let axObserver {
            if let axApplication {
                AXObserverRemoveNotification(axObserver, axApplication, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        axApplication = nil
        watchedProcessID = nil
    }

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        if let input { NSEvent.removeMonitor(input) }
        activation = nil
        input = nil
        removeWindowWatch()
    }

    isolated deinit { stop() }
}

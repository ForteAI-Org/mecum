//
//  SystemSeatSensing.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import CursorGuard
import Foundation
import Dispatch
import os
import SeatCore
import VirtualScreens
import WindowPlacement

/// SystemSeatSensing is the live witness of `SeatSensing`: the real readings,
/// each of them one call, none of them a decision.
///
/// It is a class and not a struct because it holds the display and the fence,
/// and it is `@unchecked Sendable` for the honest reason: it is read from the
/// watchdog's heartbeat, from the observer's timer and from the recovery loop,
/// and every one of those is already on the main actor. What makes it safe is
/// that it stores only two references and mutates nothing.
///
/// The one idiom worth naming is `virtualDisplayIsOnline`: membership of
/// `CGGetOnlineDisplayList` and never `CGDisplayIsOnline`. For a display that
/// has gone away that call answers `0xFFFFFFFF`, so `!= 0` reads "online"
/// exactly when the display is not there. That spelling turned up in five
/// places, including a watchdog that therefore never fired.
nonisolated final class SystemSeatSensing: SeatSensing, @unchecked Sendable {

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Session")

    private let display: VirtualDisplay
    private let fence  : CursorFence

    init(display: VirtualDisplay, fence: CursorFence) {
        self.display = display
        self.fence   = fence
    }

    // MARK: The display and the topology

    var mainDisplayID: CGDirectDisplayID { CGMainDisplayID() }

    var physicalTopologyIsUnchanged: Bool {
        MainActor.assumeIsolated { display.topology.physicalTopologyUnchanged }
    }

    /// A list that cannot be read answers false: it is no evidence of a screen
    /// connected, and `virtualDisplayIsOnline` fails closed on the same failure.
    var physicalDisplayWasAdded: Bool {
        guard let active = try? DisplayList.active() else { return false }
        return display.topology.physicalDisplayWasAdded(
            activeDisplayIDs: active,
            virtualDisplayID: display.displayID
        )
    }

    var virtualDisplayIsOnline: Bool {
        MainActor.assumeIsolated { (try? display.isOnline) == true }
    }

    var virtualDisplayBounds: CGRect {
        MainActor.assumeIsolated { display.quartzBounds }
    }

    // MARK: The fence and the cursor

    var fenceIsActive: Bool { fence.isActive }

    func fenceContainsPhysicalPoint(_ point: CGPoint) -> Bool {
        fence.containsPhysicalPoint(point)
    }

    func drainFenceSignals() -> FenceSignals { fence.drainSignals() }

    /// The global cursor, from a `CGEvent` and not from `NSEvent.mouseLocation`:
    /// the fence's region and the display bounds are Quartz coordinates, and
    /// mixing the two origins is how a fence ends up confining the cursor to
    /// the wrong half of the screen.
    var cursorLocation: CGPoint? { CGEvent(source: nil)?.location }

    // MARK: The target

    func windowGeometry(of windowNumber: Int) -> WindowReference? {
        WindowServerProbe.geometry(of: windowNumber)
    }

    /// The list `geometry` reads leaves out an ordered-out window, while its
    /// owner chain still answers: both read, so a refused gate is never absence.
    func windowIsOrderedOut(_ window: WindowReference) -> Bool {
        guard let identity = window.identity,
              case .absent = WindowServerProbe.geometryReading(of: window.windowNumber)
        else { return false }
        return WindowServerProbe.identity(of: window.windowNumber) == identity
    }

    /// The named request the surface reader's destruction proof comes from:
    /// an empty answer is destroyed, a failed one is not.
    func windowIsDestroyed(_ window: WindowReference) -> Bool {
        WindowServerProbe.surfaces(matching: [window.processID: [window.windowNumber]])?.isEmpty == true
    }

    func windowGeometryObservation(
        of window: WindowReference
    ) -> WindowGeometryObservation? {
        WindowGeometryProbe.observation(of: window)
    }

    /// Three-valued: nil says the process is gone, which is a different Issue
    /// from "the person is in it".
    func isActive(processID: Int32) -> Bool? {
        NSRunningApplication(processIdentifier: processID)?.isActive
    }

    var frontmostProcessID: Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    var focusedUserWindow: WindowReference? {
        guard let pid = frontmostProcessID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
              let number = WindowRelocator.windowNumber(of: unsafeDowncast(value, to: AXUIElement.self)),
              let window = WindowServerProbe.geometry(of: number), window.processID == pid
        else { return nil }
        return window
    }

    var focusRecoverySnapshot: FocusRecoverySnapshot? {
        MainActor.assumeIsolated { FocusRecoverySnapshot.readingWindows(in: focusEnvironment()) }
    }

    @MainActor
    func prepareFocusRecoverySnapshot() async -> FocusRecoverySnapshot? {
        await FocusRecoverySnapshot.readingWindowsConcurrently(in: focusEnvironment())
    }

    @MainActor
    func prepareFocusRecoverySnapshot(
        for processIDs: Set<Int32>
    ) async -> FocusRecoverySnapshot? {
        await FocusRecoverySnapshot.readingWindowsConcurrently(
            in     : focusEnvironment(),
            ownedBy: processIDs
        )
    }

    @MainActor
    private func focusEnvironment() -> FocusRecoverySnapshot {
        let start = DispatchTime.now().uptimeNanoseconds
        let topology = display.topology
        let physical = topology.physicalDisplays.map { CGDisplayBounds($0.displayID) }
        let topologyValid = zip(topology.physicalDisplays, physical).allSatisfy {
            rectanglesMatch($0.bounds, $1)
        }
        let valid = topologyValid && (try? display.isOnline) == true
            && CGMainDisplayID() == topology.mainDisplayID
        var snapshot = FocusRecoverySnapshot(topologyIsValid: valid,
            virtualBounds: display.quartzBounds, physicalBounds: physical, windows: [])
        snapshot.environmentNanoseconds = DispatchTime.now().uptimeNanoseconds &- start
        return snapshot
    }

    var userMayBeSwitchingApplications: Bool {
        MainActor.assumeIsolated { UserFocusWatch.hasRecentSwitchIntent }
    }

    func windowIsVisibleOnPhysicalDisplay(_ window: WindowReference) -> Bool {
        guard WindowServerProbe.orderIndex(of: window.windowNumber) != nil else { return false }
        return MainActor.assumeIsolated {
            NSScreen.screens.contains { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      number.uint32Value != display.displayID else { return false }
                // A focused user window may extend off screen or span physical
                // displays. Recovery needs a visible portion, not full containment.
                return !CGDisplayBounds(number.uint32Value).intersection(window.frame).isEmpty
            }
        }
    }

    func visibleWindowsAreVirtual(ownedBy processID: Int32) -> Bool {
        guard let descriptions = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return false }
        var found = false
        for entry in descriptions {
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  !frame.isEmpty else { continue }
            found = true
            guard virtualDisplayBounds.contains(frame) else { return false }
        }
        return found
    }

    func isBehindFrontmostWindow(windowNumber: Int, ownedBy processID: Int32) -> Bool? {
        WindowServerProbe.isBehindFrontmostWindow(
            windowNumber: windowNumber,
            ownedBy     : processID
        )
    }

    func windowOrderIndex(of windowNumber: Int) -> Int? {
        WindowServerProbe.orderIndex(of: windowNumber)
    }

    func menuWindows(ownedBy processID: Int32) -> [WindowReference] {
        WindowServerProbe.menuWindows(ownedBy: processID)
    }

    func windowSurfaces(ownedBy processIDs: Set<Int32>) -> [WindowSurface]? {
        WindowServerProbe.surfaces(ownedBy: processIDs)
    }
}

//
//  FocusRecoverySnapshot.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import Dispatch
import Foundation
import PrivateSymbols
import SeatCore
import WindowPlacement

/// Readings prepared before input and bound to one short-lived recovery attempt.
/// They include all windows visible at preparation time, not dialogs that appear
/// afterwards. An adopted or destination window absent from them cannot authorize recovery.
nonisolated public struct FocusRecoverySnapshot: Sendable {
    public let topologyIsValid: Bool
    public let virtualBounds: CGRect
    public let physicalBounds: [CGRect]
    public let windows: [WindowReference]
    var environmentNanoseconds: UInt64 = 0
    var windowsNanoseconds: UInt64 = 0

    public init(topologyIsValid: Bool, virtualBounds: CGRect,
                physicalBounds: [CGRect], windows: [WindowReference]) {
        self.topologyIsValid = topologyIsValid
        self.virtualBounds = virtualBounds
        self.physicalBounds = physicalBounds
        self.windows = windows
    }

    /// No AppKit, AX, display owner, or mutable sensing object crosses this hop.
    @concurrent
    static func readingWindowsConcurrently(in environment: Self) async -> Self {
        readingWindows(in: environment)
    }

    static func readingWindows(in environment: Self) -> Self {
        let start = DispatchTime.now().uptimeNanoseconds
        let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        var windows: [WindowReference] = []
        var complete = entries != nil
        let table = SymbolTable.shared
        let identityGate = FacilityGate.current(facility: .windowIdentity, table: table)
        for entry in entries ?? [] {
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let window = WindowServerProbe.reference(
                      processID   : pid,
                      windowNumber: number,
                      frame       : frame,
                      table       : table,
                      validatedBy : identityGate
                  ) else {
                complete = false
                break
            }
            windows.append(window)
        }
        var snapshot = Self(topologyIsValid: environment.topologyIsValid && complete,
            virtualBounds: environment.virtualBounds, physicalBounds: environment.physicalBounds,
            windows: complete ? windows : [])
        snapshot.environmentNanoseconds = environment.environmentNanoseconds
        snapshot.windowsNanoseconds = DispatchTime.now().uptimeNanoseconds &- start
        return snapshot
    }

    func containsAdoptedWindows(_ targets: [WindowReference]) -> Bool {
        !targets.isEmpty && targets.allSatisfy { target in
            guard let current = windows.first(where: { $0.hasSameIdentity(as: target) }) else { return false }
            return !current.frame.isEmpty && virtualBounds.contains(current.frame)
        }
    }

    func containsOnlyVirtualWindows(of processID: Int32) -> Bool {
        let owned = windows.filter { $0.processID == processID && !$0.frame.isEmpty }
        return !owned.isEmpty && owned.allSatisfy { virtualBounds.contains($0.frame) }
    }

    func containsUserWindow(_ destination: WindowReference, excluding targets: [WindowReference]) -> Bool {
        guard !targets.contains(where: { $0.processID == destination.processID }),
              let current = windows.first(where: { $0.hasSameIdentity(as: destination) }),
              !current.frame.isEmpty, !current.frame.intersects(virtualBounds) else { return false }
        // Match live visibility: an oversized user window still has a valid
        // destination. Virtual overlap remains excluded above.
        return physicalBounds.contains { !$0.intersection(current.frame).isEmpty }
    }
}

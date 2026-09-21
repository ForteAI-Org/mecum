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

/// FocusRecoverySnapshot binds display and window evidence to one preparation.
/// It covers every on-screen window of `coveredProcessIDs`, or every process
/// when that scope is nil. Windows created after preparation are not evidence.
nonisolated public struct FocusRecoverySnapshot: Sendable {

    /// The display topology is the one that was recorded: same physical bounds,
    /// the display online, the same main display.
    public let topologyIsValid: Bool

    /// Whether the listing was available, every row had a valid owner PID, and
    /// every window within the declared process scope resolved to an identity.
    /// An incomplete listing cannot authorize recovery, even with valid displays.
    public let windowsAreComplete: Bool

    /// The first unresolved Window ID, not its position in the list.
    /// Nil also covers an unavailable listing or a row without a Window ID.
    public let firstUnresolvedWindow: Int?

    /// The process scope whose on-screen windows were exhaustively read.
    /// Nil declares an exhaustive reading of all processes. A scoped snapshot
    /// cannot support claims about a process outside this set.
    public let coveredProcessIDs: Set<Int32>?
    public let virtualBounds: CGRect
    public let physicalBounds: [CGRect]
    public let windows: [WindowReference]
    var environmentNanoseconds: UInt64 = 0
    var windowsNanoseconds: UInt64 = 0

    /// Declares the completeness and scope of the supplied window evidence.
    /// Custom sensing implementations must report missing evidence as incomplete.
    public init(
        topologyIsValid      : Bool,
        virtualBounds        : CGRect,
        physicalBounds       : [CGRect],
        windows              : [WindowReference],
        windowsAreComplete   : Bool = true,
        firstUnresolvedWindow: Int? = nil,
        coveredProcessIDs    : Set<Int32>? = nil
    ) {
        self.topologyIsValid       = topologyIsValid
        self.windowsAreComplete    = windowsAreComplete
        self.firstUnresolvedWindow = firstUnresolvedWindow
        self.coveredProcessIDs     = coveredProcessIDs
        self.virtualBounds = virtualBounds
        self.physicalBounds = physicalBounds
        self.windows = windows
    }

    /// No AppKit, AX, display owner, or mutable sensing object crosses this hop.
    @concurrent
    static func readingWindowsConcurrently(
        in environment    : Self,
        ownedBy processIDs: Set<Int32>? = nil
    ) async -> Self {
        readingWindows(in: environment, ownedBy: processIDs)
    }

    static func readingWindows(
        in environment    : Self,
        ownedBy processIDs: Set<Int32>? = nil
    ) -> Self {
        let start = DispatchTime.now().uptimeNanoseconds
        let table = SymbolTable.shared
        let identityGate = FacilityGate.current(facility: .windowIdentity, table: table)
        var snapshot = readingWindows(
            in     : environment,
            ownedBy: processIDs,
            entries: CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
            resolve: { processID, windowNumber, frame in
                WindowServerProbe.reference(
                    processID   : processID,
                    windowNumber: windowNumber,
                    frame       : frame,
                    table       : table,
                    validatedBy : identityGate
                )
            }
        )
        snapshot.windowsNanoseconds = DispatchTime.now().uptimeNanoseconds &- start
        return snapshot
    }

    /// Reads one WindowServer listing with an attestation function supplied by the adapter.
    static func readingWindows(
        in environment    : Self,
        ownedBy processIDs: Set<Int32>?,
        entries           : [[String: Any]]?,
        resolve           : (Int32, Int, CGRect) -> WindowReference?
    ) -> Self {
        let start = DispatchTime.now().uptimeNanoseconds
        var windows: [WindowReference] = []
        var complete = entries != nil
        var unresolved: Int?
        for entry in entries ?? [] {
            guard let rawPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let pid = Int32(exactly: rawPID.int64Value), pid > 0 else {
                complete = false
                unresolved = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue
                break
            }
            // WindowServer's PID classifies the row. Only retained rows authorize
            // recovery, and each must also pass the independent ownership chain.
            if let processIDs, !processIDs.contains(pid) { continue }
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let window = resolve(pid, number, frame),
                  window.identity != nil, window.processID == pid,
                  window.windowNumber == number else {
                complete = false
                unresolved = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue
                break
            }
            windows.append(window)
        }
        var snapshot = Self(
            topologyIsValid      : environment.topologyIsValid,
            virtualBounds        : environment.virtualBounds,
            physicalBounds       : environment.physicalBounds,
            windows              : complete ? windows : [],
            windowsAreComplete   : complete,
            firstUnresolvedWindow: unresolved,
            coveredProcessIDs    : processIDs
        )
        snapshot.environmentNanoseconds = environment.environmentNanoseconds
        snapshot.windowsNanoseconds = DispatchTime.now().uptimeNanoseconds &- start
        return snapshot
    }

    func containsAdoptedWindows(_ targets: [WindowReference]) -> Bool {
        !targets.isEmpty && targets.allSatisfy { target in
            guard covers(target.processID),
                  let current = windows.first(where: { $0.hasSameIdentity(as: target) }) else { return false }
            return !current.frame.isEmpty && virtualBounds.contains(current.frame)
        }
    }

    func containsOnlyVirtualWindows(of processID: Int32) -> Bool {
        guard covers(processID) else { return false }
        let owned = windows.filter { $0.processID == processID && !$0.frame.isEmpty }
        return !owned.isEmpty && owned.allSatisfy { virtualBounds.contains($0.frame) }
    }

    /// The first on-screen window of the process that is not inside the virtual
    /// display, so a refusal names the window it refused on instead of only
    /// reporting that one exists. Nil when every window is contained, when the
    /// process has none, and when the snapshot does not cover it: those are
    /// different situations and none of them is this one.
    func firstWindowOutsideVirtualDisplay(of processID: Int32) -> WindowReference? {
        guard covers(processID) else { return nil }
        return windows.first {
            $0.processID == processID && !$0.frame.isEmpty && !virtualBounds.contains($0.frame)
        }
    }

    func containsUserWindow(_ destination: WindowReference, excluding targets: [WindowReference]) -> Bool {
        guard covers(destination.processID),
              !targets.contains(where: { $0.processID == destination.processID }),
              let current = windows.first(where: { $0.hasSameIdentity(as: destination) }),
              !current.frame.isEmpty, !current.frame.intersects(virtualBounds) else { return false }
        // Match live visibility: an oversized user window still has a valid
        // destination. Virtual overlap remains excluded above.
        return physicalBounds.contains { !$0.intersection(current.frame).isEmpty }
    }

    private func covers(_ processID: Int32) -> Bool {
        windowsAreComplete && (coveredProcessIDs?.contains(processID) ?? true)
    }
}

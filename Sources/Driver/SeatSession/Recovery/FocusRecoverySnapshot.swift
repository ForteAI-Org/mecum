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
///
/// ## The one kind of window it leaves out, and why that is not a gap
///
/// A row at or below `WindowServerProbe.desktopIconLevel` is excluded when the
/// listing is read. The Finder draws one desktop window per display and always
/// has, so with the Finder adopted `containsOnlyVirtualWindows` could never be
/// true, on any machine, by construction: measured on 26A5425a as Window ID 39
/// at (0, 0, 1512, 982) on the physical display while the seat held the virtual
/// one. Excluding it does not weaken containment. A window at that level is
/// behind every ordinary window, the person's own included, so it cannot be on
/// top of their work, and being on top of their work is the whole of what
/// containment protects against.
///
/// The exclusion is by level, asked of the system, and never by owner name,
/// title or size. It applies to every predicate here, which is deliberate: a
/// desktop window is not a destination either, so `containsUserWindow` can no
/// longer find one, and a restoration to the desktop is refused rather than
/// made.
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
    /// Exact identities independently listed as off screen. They still belong
    /// to the seat and remain owed their original geometry; their absence from
    /// the on-screen list is not a containment failure or destruction proof.
    public let nonVisibleWindows: Set<WindowIdentity>
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
        coveredProcessIDs    : Set<Int32>? = nil,
        nonVisibleWindows    : Set<WindowIdentity> = []
    ) {
        self.topologyIsValid       = topologyIsValid
        self.windowsAreComplete    = windowsAreComplete
        self.firstUnresolvedWindow = firstUnresolvedWindow
        self.coveredProcessIDs     = coveredProcessIDs
        self.virtualBounds = virtualBounds
        self.physicalBounds = physicalBounds
        self.windows = windows
        self.nonVisibleWindows = nonVisibleWindows
    }

    /// No AppKit, AX, display owner, or mutable sensing object crosses this hop.
    @concurrent
    static func readingWindowsConcurrently(
        in environment    : Self,
        ownedBy processIDs: Set<Int32>? = nil
    ) async -> Self {
        readingWindows(in: environment, ownedBy: processIDs)
    }

    /// The live walk, and the third one in the kit. It runs once a second for as
    /// long as a seat holds a window, so the gate is evaluated once for the
    /// whole listing and one memo of owner connections is shared by every row.
    /// Ten windows of one application then cost twenty owner readings and one
    /// process resolution instead of twenty and ten: 22 round trips where a
    /// per-row memo pays 40. The memo is a local of this call and dies with it,
    /// because a connection ID reused by a new process would otherwise name a
    /// live PID for a dead one.
    static func readingWindows(
        in environment    : Self,
        ownedBy processIDs: Set<Int32>? = nil
    ) -> Self {
        let start = DispatchTime.now().uptimeNanoseconds
        let table = SymbolTable.shared
        let identityGate = FacilityGate.current(facility: .windowIdentity, table: table)
        var processes = WindowServerProbe.OwnerProcesses()
        var snapshot = readingWindows(
            in     : environment,
            ownedBy: processIDs,
            entries: CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
            nonVisibleEntries: CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
            resolve: { processID, windowNumber, frame in
                WindowServerProbe.reference(
                    processID   : processID,
                    windowNumber: windowNumber,
                    frame       : frame,
                    table       : table,
                    validatedBy : identityGate,
                    memoizing   : &processes
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
        nonVisibleEntries : [[String: Any]]? = nil,
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
            // The desktop is not a window anybody drives, and it cannot be on top
            // of the person's work, which is the whole of what containment checks.
            if let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
               layer <= WindowServerProbe.desktopIconLevel { continue }
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
        var nonVisible: Set<WindowIdentity> = []
        let visibleNumbers = Set(windows.map(\.windowNumber))
        let rows = nonVisibleEntries ?? []
        let counts = Dictionary(
            rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
                .map { ($0, 1) },
            uniquingKeysWith: +
        )
        for row in rows {
            // Some off-screen rows omit the visibility flag. Their positive
            // identity in this listing plus absence from the complete visible
            // listing supplies the proof; an explicit visible flag contradicts it.
            guard complete,
                  row[kCGWindowIsOnscreen as String] == nil
                    || (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == false,
                  let pidValue = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let pid = Int32(exactly: pidValue.int64Value), pid > 0,
                  processIDs?.contains(pid) ?? true,
                  let number = (row[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  counts[number] == 1, !visibleNumbers.contains(number),
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let reference = resolve(pid, number, frame),
                  reference.processID == pid, reference.windowNumber == number,
                  let identity = reference.identity
            else { continue }
            nonVisible.insert(identity)
        }
        var snapshot = Self(
            topologyIsValid      : environment.topologyIsValid,
            virtualBounds        : environment.virtualBounds,
            physicalBounds       : environment.physicalBounds,
            windows              : complete ? windows : [],
            windowsAreComplete   : complete,
            firstUnresolvedWindow: unresolved,
            coveredProcessIDs    : processIDs,
            nonVisibleWindows    : nonVisible
        )
        snapshot.environmentNanoseconds = environment.environmentNanoseconds
        snapshot.windowsNanoseconds = DispatchTime.now().uptimeNanoseconds &- start
        return snapshot
    }

    func containsAdoptedWindows(_ targets: [WindowReference]) -> Bool {
        !targets.isEmpty && targets.allSatisfy { target in
            guard covers(target.processID) else { return false }
            guard let current = windows.first(where: { $0.hasSameIdentity(as: target) }) else {
                return target.identity.map(nonVisibleWindows.contains) == true
            }
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

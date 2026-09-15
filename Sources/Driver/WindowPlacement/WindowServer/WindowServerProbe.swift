//
//  WindowServerProbe.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Darwin
import PrivateSymbols
import SeatCore
import VirtualScreens

/// WindowServerProbe reads window geometry and order straight from the window
/// server, with no accessibility call anywhere in it.
///
/// It is the kit's **second, independent** witness. A window's own reading of
/// its frame and the window server's are updated at different moments, so a
/// placement confirmed by one alone is not confirmed: every geometric check in
/// the kit takes both, and the recovery path of a seat takes only this one,
/// because it has to keep working while the target's accessibility interface
/// is momentarily unreadable.
///
/// `CGWindowListCopyWindowInfo` allocates a dictionary per window and is by far
/// the most expensive geometry call: 609 of the 787 allocations once measured
/// for one click came from it. Coordinate Commands now pay that cost twice:
/// once before construction and once immediately before the first post. Key
/// Commands keep using `identity(of:)`, whose cached gate and fixed ownership
/// calls do not create a window-list dictionary.
nonisolated public enum WindowServerProbe {

    /// The public Process Manager mapping documented by the macOS SDK. Swift 6
    /// no longer imports `ProcessSerialNumber`, so the two-word value crosses
    /// this call as raw storage with the header's exact pointer ABI.
    private typealias GetProcessPID = @convention(c) (
        UnsafeRawPointer?,
        UnsafeMutablePointer<Int32>?
    ) -> Int32

    private struct ProcessSerialNumberValue: Equatable {
        var high: UInt32 = 0
        var low : UInt32 = 0
    }

    /// `GetProcessPID` is a documented, deprecated SDK function rather than a
    /// private primitive. Missing it refuses identity resolution; it is never
    /// replaced with a guess from a PID that merely happens to be alive.
    private static let getProcessPID: GetProcessPID? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework"
            + "/Frameworks/HIServices.framework/HIServices"
        guard let image = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let address = dlsym(image, "GetProcessPID")
        else { return nil }
        return unsafeBitCast(address, to: GetProcessPID.self)
    }()

    /// The window server's own reading of one Window ID: owner and frame.
    /// Scoped to the requested id, so a window that is gone answers `nil`
    /// rather than a neighbour's geometry.
    public static func geometry(
        of windowNumber       : Int,
        allowUnvalidatedBuild : Bool = false,
        table                 : SymbolTable = .shared
    ) -> WindowReference? {

        let gate = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        guard let windowID = CGWindowID(exactly: windowNumber), windowID != 0,
              let firstIdentity = identity(
                  of         : windowNumber,
                  table      : table,
                  validatedBy: gate
              ),
              let windows = CGWindowListCopyWindowInfo(
                  .optionIncludingWindow,
                  windowID
              ) as? [[String: Any]],
              let entry = windows.first(where: { number(of: $0) == windowNumber }),
              let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
              processID == firstIdentity.processID,
              identity(
                  of         : windowNumber,
                  table      : table,
                  validatedBy: gate
              ) == firstIdentity
        else { return nil }

        return WindowReference(identity: firstIdentity, frame: frame)
    }

    /// The WindowServer ownership chain for one Window ID, read twice and
    /// accepted only when every link agrees.
    ///
    /// `SLSGetWindowOwner` binds the Window ID to its connection,
    /// `SLSGetConnectionPSN` binds that connection to one process lifetime, and
    /// the documented `GetProcessPID` maps that lifetime back to the PID. This
    /// uses no Accessibility API and returns `nil` when any relationship cannot
    /// be proved.
    public static func identity(
        of windowNumber       : Int,
        allowUnvalidatedBuild : Bool = false,
        table                 : SymbolTable = .shared
    ) -> WindowIdentity? {

        let gate = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        return identity(of: windowNumber, table: table, validatedBy: gate)
    }

    /// Resolves identity under a gate already evaluated by the owning Facility.
    /// Package clients cache this gate so the per-Command revalidation performs
    /// only the three ownership calls and the documented PID mapping.
    package static func identity(
        of windowNumber: Int,
        table          : SymbolTable,
        validatedBy gate: FacilityGate
    ) -> WindowIdentity? {

        guard gate.mayAct,
              let windowID = UInt32(exactly: windowNumber), windowID != 0,
              let mainConnectionID = table.function(
                  .mainConnectionID,
                  as: SymbolABI.MainConnectionID.self
              ),
              let getWindowOwner = table.function(
                  .getWindowOwner,
                  as: SymbolABI.GetWindowOwner.self
              ),
              let getConnectionPSN = table.function(
                  .getConnectionPSN,
                  as: SymbolABI.GetConnectionPSN.self
              ),
              let getProcessPID
        else { return nil }

        let connectionID = mainConnectionID()
        guard connectionID != 0,
              let first = identity(
                  windowNumber    : windowID,
                  connectionID    : connectionID,
                  getWindowOwner  : getWindowOwner,
                  getConnectionPSN: getConnectionPSN,
                  getProcessPID   : getProcessPID
              ),
              let second = identity(
                  windowNumber    : windowID,
                  connectionID    : connectionID,
                  getWindowOwner  : getWindowOwner,
                  getConnectionPSN: getConnectionPSN,
                  getProcessPID   : getProcessPID
              ),
              first == second
        else { return nil }

        return first
    }

    /// Attests one row of a WindowServer list under a gate the caller evaluated
    /// once for the whole list. This avoids a second list allocation per window
    /// while still binding every row to its owner connection and process life.
    package static func reference(
        processID       : Int32,
        windowNumber    : Int,
        frame           : CGRect,
        table           : SymbolTable,
        validatedBy gate: FacilityGate
    ) -> WindowReference? {

        guard let identity = identity(
            of         : windowNumber,
            table      : table,
            validatedBy: gate
        ), identity.processID == processID else { return nil }
        return WindowReference(identity: identity, frame: frame)
    }

    /// This window's place in the front to back order, or `nil` when it is not
    /// on screen. The index spans every display, so it answers "is this in
    /// front of that", never "is this on stage".
    public static func orderIndex(of windowNumber: Int) -> Int? {
        orderedWindows()?.firstIndex { number(of: $0) == windowNumber }
    }

    /// The level a contextual menu is drawn at, asked of the system rather than
    /// written down. It is 101 on every build measured, and the reason it is
    /// read is that a constant copied out of a header is exactly the kind of
    /// fact this package has already caught being wrong.
    public static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Every window this process owns that is drawn at the pop up menu level
    /// and is on screen: the whole oracle for "did a contextual menu open".
    ///
    /// It is here and not in `geometry(of:)` because a menu has no Window ID
    /// anybody knew in advance, so it cannot be looked up: it is found by owner
    /// and level or it is not found at all. And it is the **only** oracle: an
    /// open contextual menu is not in the target's accessibility tree, under
    /// the application or under the window, on either family measured, so a
    /// reading that asks the tree answers "no menu" for a menu that is on the
    /// screen. That reading is what produced this package's earlier verdict
    /// that a background application opens no menu at all.
    ///
    /// The on-screen filter is deliberate and it is what makes the answer
    /// positive evidence: the window server keeps menu-level windows of past
    /// menus around off screen, and one of those is not a menu the caller just
    /// opened.
    public static func menuWindows(ownedBy processID: Int32) -> [WindowReference] {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        return windows.compactMap { description in
            guard owner(of: description) == processID,
                  layer(of: description) == popUpMenuLevel,
                  let windowNumber = number(of: description),
                  let window = geometry(of: windowNumber),
                  window.processID == processID
            else { return nil }
            return window
        }
        .sorted { $0.windowNumber < $1.windowNumber }
    }

    /// The frontmost normal-layer window whose frame reaches a display. It is
    /// how a Seat Host asks which window is on stage on the Virtual Display
    /// without asking Stage Manager anything.
    public static func frontmostWindow(onDisplayBounds displayBounds: CGRect) -> Int? {
        orderedWindows()?.first { description in
            guard layer(of: description) == 0, let bounds = frame(of: description) else {
                return false
            }
            let intersection = bounds.intersection(displayBounds)
            return intersection.width > 1 && intersection.height > 1
        }
        .flatMap(number(of:))
    }

    /// The frontmost normal-layer window of a process. Its only use is as the
    /// handle the identity chain needs: `SLSGetWindowOwner` on it yields the
    /// process serial number the two Preparation records are addressed to.
    public static func frontWindowNumber(ownedBy processID: Int32) -> Int? {
        orderedWindows()?.first { description in
            owner(of: description) == processID && layer(of: description) == 0
        }
        .flatMap(number(of:))
    }

    /// Whether the target window sits behind the person's frontmost window.
    /// `nil` when either window is not in the on-screen list, which is a
    /// missing reading and not a `false`: a check that read "not behind" from
    /// an absent window would fail a seat for a window that was merely being
    /// redrawn.
    public static func isBehindFrontmostWindow(
        windowNumber: Int,
        ownedBy processID: Int32
    ) -> Bool? {

        guard let windows = orderedWindows(),
              let targetIndex = windows.firstIndex(where: { number(of: $0) == windowNumber }),
              let userIndex = windows.firstIndex(where: {
                  owner(of: $0) == processID && layer(of: $0) == 0
              })
        else { return nil }

        // The list runs front to back, so a larger index is further back.
        return targetIndex > userIndex
    }

    /// An AppKit point (origin bottom left of its own screen) as a Quartz point
    /// (origin top left of the main display).
    ///
    /// The conversion is per screen and not against the main display's height,
    /// because with more than one display those differ and the difference is
    /// exactly the offset that puts a click on the wrong screen. The fallback
    /// for a point on no screen at all flips against the first screen, which is
    /// wrong by the same offset and says so: it exists so a caller gets a
    /// number instead of a crash.
    @MainActor
    public static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let displayID = ScreenRegistration.displayID(of: screen)
        else {
            let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
            return CGPoint(x: point.x, y: mainHeight - point.y)
        }

        let bounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: bounds.minX + point.x - screen.frame.minX,
            y: bounds.minY + screen.frame.maxY - point.y
        )
    }

    // MARK: Reading one entry of the list

    private static func orderedWindows() -> [[String: Any]]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    }

    private static func number(of description: [String: Any]) -> Int? {
        (description[kCGWindowNumber as String] as? NSNumber)?.intValue
    }

    private static func owner(of description: [String: Any]) -> Int32? {
        (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    private static func layer(of description: [String: Any]) -> Int? {
        (description[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    private static func frame(of description: [String: Any]) -> CGRect? {
        guard let rawBounds = description[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
    }

    private static func identity(
        windowNumber    : UInt32,
        connectionID    : Int32,
        getWindowOwner  : SymbolABI.GetWindowOwner,
        getConnectionPSN: SymbolABI.GetConnectionPSN,
        getProcessPID   : GetProcessPID
    ) -> WindowIdentity? {

        var ownerConnectionID: Int32 = 0
        guard getWindowOwner(connectionID, windowNumber, &ownerConnectionID) == 0,
              ownerConnectionID != 0
        else { return nil }

        var serialNumber = ProcessSerialNumberValue()
        let serialResult = withUnsafeMutablePointer(to: &serialNumber) { pointer in
            getConnectionPSN(ownerConnectionID, UnsafeMutableRawPointer(pointer))
        }
        guard serialResult == 0 else { return nil }

        var processID: Int32 = 0
        let processResult = withUnsafePointer(to: &serialNumber) { pointer in
            getProcessPID(UnsafeRawPointer(pointer), &processID)
        }
        guard processResult == 0, processID > 0 else { return nil }

        return WindowIdentity(
            process: ProcessIdentity(
                processID       : processID,
                serialNumberHigh: serialNumber.high,
                serialNumberLow : serialNumber.low
            ),
            windowNumber     : Int(windowNumber),
            ownerConnectionID: ownerConnectionID
        )
    }
}

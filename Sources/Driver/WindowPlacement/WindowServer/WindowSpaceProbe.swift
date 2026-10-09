//
//  WindowSpaceProbe.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import ColorSync
import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore

/// WindowSpaceProbe reads which desktops (Spaces) exist and which one a window
/// is on, through two read-only SkyLight calls (ADR 0037).
///
/// It writes nothing: no window is moved between desktops and no desktop is
/// switched. Every answer is optional on purpose. When the Facility is
/// unavailable, a symbol did not resolve or the reply has an unexpected shape,
/// the answer is `nil`, and a caller that needs the desktop says "unknown"
/// instead of claiming a success it cannot prove.
///
/// Measured on 26A434 (2026-10-09): a window's desktop is the one it was on
/// before the seat took it, and a window the person left on another desktop is
/// absent from every public window list while `SLSCopySpacesForWindows` still
/// names its desktop.
nonisolated public enum WindowSpaceProbe {

    /// `SLSCopySpacesForWindows` mask for every kind of desktop, fullscreen
    /// ones included.
    private static let everyKindOfSpace: Int32 = 0x7

    /// The desktops of every display, or `nil` when they cannot be read.
    public static func layout(
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared
    ) -> DesktopLayout? {

        guard let connection = connection(allowUnvalidatedBuild, table),
              let copy = table.function(
                  .copyManagedDisplaySpaces,
                  as: SymbolABI.CopyManagedDisplaySpaces.self
              ),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        return layout(from: displays, displayID: displayID(forIdentifier:))
    }

    /// The desktops one window is on, or `nil` when they cannot be read. An
    /// empty array is a window the window server places on no desktop.
    public static func spaces(
        of windowNumber      : Int,
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared
    ) -> [Int]? {

        guard windowNumber > 0,
              let connection = connection(allowUnvalidatedBuild, table),
              let copy = table.function(
                  .copySpacesForWindows,
                  as: SymbolABI.CopySpacesForWindows.self
              ),
              let reply = copy(connection, everyKindOfSpace, [windowNumber] as CFArray)?
                  .takeRetainedValue()
        else { return nil }
        return (reply as? [NSNumber])?.map(\.intValue)
    }

    /// The reply of `SLSCopyManagedDisplaySpaces` as a layout. Pure, so its
    /// handling of a malformed row is a unit test. A display whose current
    /// desktop is missing is left out rather than guessed, and `nil` is
    /// answered when no display could be read at all.
    package static func layout(
        from displays: [[String: Any]],
        displayID    : (String) -> CGDirectDisplayID?
    ) -> DesktopLayout? {

        let parsed = displays.compactMap { row -> DesktopLayout.Display? in
            guard let current = (row["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int,
                  let spaces = row["Spaces"] as? [[String: Any]]
            else { return nil }
            return DesktopLayout.Display(
                displayID: (row["Display Identifier"] as? String).flatMap(displayID),
                spaces   : spaces.compactMap { $0["ManagedSpaceID"] as? Int },
                current  : current
            )
        }
        return parsed.isEmpty ? nil : DesktopLayout(displays: parsed)
    }

    private static func connection(_ allowUnvalidatedBuild: Bool, _ table: SymbolTable) -> Int32? {
        let gate = FacilityGate.current(
            facility             : .windowSpaces,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        guard gate.mayAct,
              let mainConnectionID = table.function(
                  .mainConnectionID,
                  as: SymbolABI.MainConnectionID.self
              )
        else { return nil }
        let connection = mainConnectionID()
        return connection == 0 ? nil : connection
    }

    /// The online display whose UUID is the window server's identifier. The
    /// literal `Main` is what the window server publishes when the displays
    /// share one set of desktops.
    private static func displayID(forIdentifier identifier: String) -> CGDirectDisplayID? {
        if identifier == "Main" { return CGMainDisplayID() }
        var count = UInt32.zero
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &identifiers, &count) == .success else { return nil }
        return identifiers.prefix(Int(count)).first { candidate in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(candidate)?.takeRetainedValue()
            else { return false }
            return (CFUUIDCreateString(nil, uuid) as String)
                .caseInsensitiveCompare(identifier) == .orderedSame
        }
    }
}

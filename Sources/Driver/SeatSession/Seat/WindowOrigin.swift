//
//  WindowOrigin.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import CoreGraphics
import SeatCore
import WindowPlacement

/// WindowOrigin is where one window of an application stood in the User Seat
/// when the application was handed over, before the seat moved anything of it.
///
/// It exists because the seat takes some windows in place: the display's own
/// creation can move an application's windows into the Virtual Display before
/// the seat moves anything, and the frame, display and desktop it would record
/// for them there are the Virtual Display's. The return would then be a no-op at
/// the wrong place, and the display going away would put them on the first
/// desktop of the main display (ADR 0037). A reading taken before that keeps
/// their own place.
nonisolated package struct WindowOrigin: Sendable, Equatable {

    /// The window's own accessibility body, which is what a return writes back
    /// through `AXPosition`. The window server's frame when the body could not
    /// be read.
    package let body: CGRect

    /// The window server's rectangle for the same window in the same place, the
    /// oracle the return is verified against. Nil when it does not describe the
    /// body (a Stage Manager thumbnail), which is then no oracle at all.
    package let serverFrame: CGRect?

    /// The physical display that held the window.
    package let displayID: CGDirectDisplayID?

    /// The desktop the window was on, nil when it was not read or the window was
    /// on several desktops.
    package let spaceID: Int?

    package init(body: CGRect, serverFrame: CGRect?, displayID: CGDirectDisplayID?, spaceID: Int?) {
        self.body        = body
        self.serverFrame = serverFrame
        self.displayID   = displayID
        self.spaceID     = spaceID
    }
}

// MARK: - Reading

extension WindowOrigin {

    /// The physical display whose bounds hold the centre of the rectangle, nil
    /// when none does (a window parked off the edge, legitimately).
    static func physicalDisplay(containing frame: CGRect) -> CGDirectDisplayID? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var count  = UInt32.zero
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &identifiers, &count) == .success else { return nil }
        return identifiers.prefix(Int(count)).first { CGDisplayBounds($0).contains(centre) }
    }

    /// The place of every visible, ordinary window of one process that is not
    /// inside `bounds`, the Virtual Display when there is one.
    ///
    /// The sources are passed in: the seat reads through its own sensing, and
    /// the broker reads before any seat or display exists. A window with no
    /// readable body is recorded at the window server's rectangle, and one with
    /// no desktop reading carries no desktop.
    static func read(
        surfaces        : [WindowSurface],
        of process      : ProcessIdentity,
        excluding bounds: CGRect?,
        body            : (WindowReference) -> CGRect?,
        display         : (CGRect) -> CGDirectDisplayID?,
        spaces          : (Int) -> [Int]?
    ) -> [WindowIdentity: WindowOrigin] {

        var origins: [WindowIdentity: WindowOrigin] = [:]
        for surface in surfaces where surface.level == 0 && surface.isVisible {
            let reference = surface.reference
            guard let identity = reference.identity, identity.process == process,
                  !(bounds?.contains(CGPoint(x: reference.frame.midX, y: reference.frame.midY)) ?? false)
            else { continue }
            let desktops = spaces(reference.windowNumber)
            let own      = body(reference)
            let describesBody = own.map {
                VirtualWindowPlacementCheck.framesMatch(
                    reference.frame,
                    $0,
                    tolerance: VirtualWindowPlacementCheck.crossSourceTolerance
                )
            } ?? true
            origins[identity] = WindowOrigin(
                body       : own ?? reference.frame,
                serverFrame: describesBody ? reference.frame : nil,
                displayID  : display(reference.frame),
                spaceID    : desktops?.count == 1 ? desktops?.first : nil
            )
        }
        return origins
    }

    /// The same reading taken from the system, for the one moment it has to be
    /// right: before the Virtual Display exists. The display's creation and the
    /// topology transaction that follows can move an application's windows
    /// (measured with TextEdit and an external display: 70 ms after the display
    /// was up, no window of the application was outside it), so nothing read
    /// after it says where they were.
    package static func readBeforeHostStarts(
        processID       : Int32,
        excluding bounds: CGRect? = nil
    ) -> [WindowIdentity: WindowOrigin] {

        guard let surfaces = WindowServerProbe.surfaces(ownedBy: [processID]),
              let process = surfaces.lazy.compactMap({ $0.reference.identity?.process }).first
        else { return [:] }
        return read(
            surfaces : surfaces,
            of       : process,
            excluding: bounds,
            body     : { (try? WindowRelocator.frame(of: $0)) ?? nil },
            display  : physicalDisplay(containing:),
            spaces   : { WindowSpaceProbe.spaces(of: $0) }
        )
    }
}

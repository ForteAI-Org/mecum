//
//  DesktopSpaces.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import CoreGraphics

/// DesktopLayout is the desktops (Spaces) of every display at one instant, as the
/// window server publishes them: which Space ids each display has and which one
/// it shows now.
///
/// It is a value read once and compared, never a handle. Space ids are the
/// window server's `ManagedSpaceID`, an integer that is stable while the desktop
/// exists and is not reused for another one in a session.
nonisolated public struct DesktopLayout: Sendable, Equatable {

    /// One display's desktops.
    nonisolated public struct Display: Sendable, Equatable {

        /// The display, or nil when the window server's identifier could not
        /// be tied to an online display.
        public let displayID: CGDirectDisplayID?

        /// Every desktop of the display, in the order the window server lists
        /// them.
        public let spaces: [Int]

        /// The desktop the display shows now.
        public let current: Int

        public init(displayID: CGDirectDisplayID?, spaces: [Int], current: Int) {
            self.displayID = displayID
            self.spaces    = spaces
            self.current   = current
        }
    }

    public let displays: [Display]

    public init(displays: [Display]) {
        self.displays = displays
    }

    /// The display that owns the desktop, or nil when no display lists it, which
    /// is what a desktop the person has closed is.
    public func display(holding space: Int) -> Display? {
        displays.first { $0.spaces.contains(space) }
    }

    /// The display with this id, or nil when it is not in the layout.
    public func display(withID displayID: CGDirectDisplayID) -> Display? {
        displays.first { $0.displayID == displayID }
    }

    /// True when some display shows the desktop now.
    public func isShown(_ space: Int) -> Bool {
        displays.contains { $0.current == space }
    }
}

/// SpaceReturnTarget is the desktop a window that goes back to the User Seat is
/// owed, decided from what was recorded when the seat took it.
nonisolated public enum SpaceReturnTarget: Sendable, Equatable {

    /// The desktop the window was on, which still exists.
    case original(Int)

    /// The desktop it was on is gone, so the one its display shows now.
    case currentOfOriginalDisplay(Int)

    /// Nothing provable: the origin was not read, the layout is not available or
    /// the display is not in it. A verification against this claims nothing.
    case unknown
}

/// SpaceVerdict is what a reading of a window's desktops says about its return.
nonisolated public enum SpaceVerdict: Sendable, Equatable {

    /// The window is on the desktop it is owed.
    case inPlace

    /// The window is somewhere else, which is the fault this exists to name.
    case otherSpace

    /// The reading or the target is missing, so the return is neither proved
    /// nor refuted on this axis.
    case unknown
}

/// SpaceReturn decides which desktop a returning window is owed and whether a
/// reading says it is there. Both are pure and read nothing.
nonisolated public enum SpaceReturn {

    /// The desktop owed to a window recorded at `originalSpace` on
    /// `originalDisplay`.
    ///
    /// The original desktop wins while any display still lists it. When it is
    /// gone, or was never recorded but the display is known, the display's
    /// current desktop is the fallback: it is where an application window lands
    /// when a position is written on that display. A missing layout or display
    /// answers `unknown` and never invents a desktop.
    public static func target(
        originalSpace  : Int?,
        originalDisplay: CGDirectDisplayID?,
        in layout      : DesktopLayout?
    ) -> SpaceReturnTarget {

        guard let layout else { return .unknown }
        if let originalSpace, layout.display(holding: originalSpace) != nil {
            return .original(originalSpace)
        }
        // A recorded desktop that is gone falls back to its display's current one.
        // A window with no recorded desktop is not judged: the origin is unknown.
        guard originalSpace != nil,
              let originalDisplay,
              let display = layout.display(withID: originalDisplay)
        else { return .unknown }
        return .currentOfOriginalDisplay(display.current)
    }

    /// Whether the desktops a window is on put it at the target.
    ///
    /// A window on several desktops (assigned to all of them) is in place when
    /// the target is one of them. An empty or missing reading is `unknown`: a
    /// window with no desktop is hidden or being moved, and no verdict follows.
    public static func verdict(windowSpaces: [Int]?, target: SpaceReturnTarget) -> SpaceVerdict {

        guard let windowSpaces, !windowSpaces.isEmpty else { return .unknown }
        switch target {
            case .original(let space), .currentOfOriginalDisplay(let space):
                return windowSpaces.contains(space) ? .inPlace : .otherSpace
            case .unknown:
                return .unknown
        }
    }

    /// True when a window exists, is on desktops the layout knows, and none of
    /// them is shown now: it is on another desktop of its display and no public
    /// window list names it.
    public static func isOnAnotherDesktop(
        windowSpaces: [Int]?,
        in layout    : DesktopLayout?
    ) -> Bool {

        guard let windowSpaces, !windowSpaces.isEmpty, let layout else { return false }
        return windowSpaces.allSatisfy { layout.display(holding: $0) != nil && !layout.isShown($0) }
    }
}

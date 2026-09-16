//
//  SeatSensing.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CursorGuard
import SeatCore

/// SeatSensing is every reading the session layer takes of the running system,
/// behind one role protocol so that the state machine, the watchdog and the
/// recovery policy can be driven without a Mac.
///
/// It is the only seam of its kind here, on purpose. The verdicts are pure
/// functions over these readings (`SeatWatchdog`, `SeatStateMachine`,
/// `WindowRecoveryPlan`), so a fake that answers the readings is enough to run
/// the whole machine in a unit test: no virtual display, no event tap, no
/// Accessibility grant, no Screen Recording.
///
/// Everything here is a **reading**. Nothing in this protocol writes, posts or
/// moves anything: that is `WindowPlacing` and `CommandSending`, which are
/// separate for the same reason, and which a test replaces with fakes that
/// record what was asked of them.
///
/// It is `nonisolated` because the watchdog's heartbeat and the recovery loop
/// both call it, and neither should pay an actor hop for a `CGDisplayBounds`.
nonisolated public protocol SeatSensing: Sendable {

    // MARK: The display and the topology

    /// The display CoreGraphics currently calls main. Every Quartz coordinate
    /// the seat holds was taken relative to it.
    var mainDisplayID: CGDirectDisplayID { get }

    /// True when every physical display still has the bounds the seat's
    /// coordinates were computed in.
    var physicalTopologyIsUnchanged: Bool { get }

    /// True when the virtual display is a member of the online display list.
    /// Membership, never `CGDisplayIsOnline`: for a display that has gone away
    /// that call answers `0xFFFFFFFF`, so `!= 0` reads "online" exactly when
    /// the display is not there. That spelling turned up in five places.
    var virtualDisplayIsOnline: Bool { get }

    /// The virtual display's bounds in Quartz coordinates, empty when there is
    /// no display.
    var virtualDisplayBounds: CGRect { get }

    // MARK: The fence and the cursor

    /// True when the fence's tap is installed and enabled right now.
    var fenceIsActive: Bool { get }

    /// True when the point is inside the union of the person's displays.
    func fenceContainsPhysicalPoint(_ point: CGPoint) -> Bool

    /// Everything the tap callback latched since the last drain, and it resets
    /// the counters. It is the fence's half of the watchdog contract:
    /// the fence corrects an escaping pointer **inside** the event that carried
    /// it, so a poll taken afterwards finds the pointer back inside and sees
    /// nothing at all.
    func drainFenceSignals() -> FenceSignals

    /// The global cursor position, or nil when it cannot be read, which is an
    /// invariant violation of its own and not a zero.
    var cursorLocation: CGPoint? { get }

    // MARK: The target

    /// The window server's geometry for a Window ID, or nil when the window is
    /// not readable. Window server and not Accessibility: an application
    /// publishes its own geometry and the server's at different moments.
    func windowGeometry(of windowNumber: Int) -> WindowReference?

    /// An attested identity, frame and display scale read for one known window.
    /// Session uses this seam when it must construct its own menu coordinate;
    /// ordinary consumer coordinates bring their observation with them.
    func windowGeometryObservation(
        of window: WindowReference
    ) -> WindowGeometryObservation?

    /// True when the application is active, false when it is not, nil when the
    /// process is gone. The three-way answer is the difference between
    /// `targetActivated` and `processUnavailable`.
    func isActive(processID: Int32) -> Bool?

    /// The person's frontmost application, or nil.
    var frontmostProcessID: Int32? { get }

    /// Read-only focus witness, with no fallback to an arbitrary window.
    var focusedUserWindow: WindowReference? { get }

    /// Synchronous snapshot used by the default pre-action preparation method.
    /// Nil means recovery cannot be armed; activation never falls back to a scan.
    var focusRecoverySnapshot: FocusRecoverySnapshot? { get }

    /// Prepare before input, never in the activation callback. Live sensing
    /// reads display state on MainActor and enumerates windows off that actor.
    @MainActor func prepareFocusRecoverySnapshot() async -> FocusRecoverySnapshot?
    var userMayBeSwitchingApplications: Bool { get }
    func windowIsVisibleOnPhysicalDisplay(_ window: WindowReference) -> Bool
    func visibleWindowsAreVirtual(ownedBy processID: Int32) -> Bool

    /// True when the window is behind the frontmost window of that process,
    /// nil when the relation cannot be established.
    func isBehindFrontmostWindow(windowNumber: Int, ownedBy processID: Int32) -> Bool?

    /// The window's index in the global window order, or nil.
    func windowOrderIndex(of windowNumber: Int) -> Int?

    /// Every window of that process the window server draws at the pop up menu
    /// level and shows on screen.
    ///
    /// It is the whole oracle for "is a contextual menu of the target open",
    /// and it is a window server reading because there is no other: such a menu
    /// is absent from the target's accessibility tree on both families
    /// measured, so a reading taken there answers "no menu" while one is on the
    /// screen. An earlier verdict of this package was exactly that mistake.
    func menuWindows(ownedBy processID: Int32) -> [WindowReference]
}

extension SeatSensing {
    public func windowGeometryObservation(
        of window: WindowReference
    ) -> WindowGeometryObservation? { nil }
    public var focusedUserWindow: WindowReference? { nil }
    nonisolated public var focusRecoverySnapshot: FocusRecoverySnapshot? { nil }
    @MainActor public func prepareFocusRecoverySnapshot() async -> FocusRecoverySnapshot? {
        focusRecoverySnapshot
    }
    public var userMayBeSwitchingApplications: Bool { false }
    public func windowIsVisibleOnPhysicalDisplay(_ window: WindowReference) -> Bool { false }
    public func visibleWindowsAreVirtual(ownedBy processID: Int32) -> Bool { false }
}

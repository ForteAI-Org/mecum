//
//  WindowRelocator.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os
import PrivateSymbols
import SeatCore
import VirtualScreens

/// WindowRelocator is the kit's **entire** use of the accessibility API, and
/// the reason `Documentation/Driver/adr/Adr0004AccessibilityOnlyForPlacement.md`
/// exists: `AXPosition` to move a window onto the
/// Virtual Display, `kAXRaiseAction` to bring it on stage, and
/// `_AXUIElementGetWindow` to find the element behind a Window ID. It never
/// reads an element tree, never asks a control for its value and never performs
/// an action on one. Everything else the kit does to a window is a private
/// input primitive, on purpose: accessibility is not a reliable control
/// surface, and letting it become an implicit fallback is exactly what the
/// research this kit comes from ruled out.
///
/// Geometry and title attributes are read only on window elements: the application's
/// `AXWindows` list, because `_AXUIElementGetWindow` maps an element to an id
/// and not the reverse, and `AXTitle` plus `AXSize` on the structural recovery
/// path, where a window that momentarily has no associable Window ID is matched
/// by exactly one title and size or not at all. Return verification also reads
/// AXPosition and AXSize to identify the body behind a server thumbnail.
///
/// Staging confirmation comes from WindowServer. A window's own reading and the
/// server's are updated at different moments, so `stage` waits for two
/// consecutive agreeing readings from `WindowServerProbe` before it calls the
/// window staged. `move` deliberately does not: what a move has to be confirmed
/// against is the seat's whole placement check, guard included, and that
/// belongs to the layer that owns the seat.
nonisolated public enum WindowRelocator {

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "display")

    /// The primitive the relocator needs on top of the Accessibility grant.
    /// `_AXUIElementGetWindow` is private, so it is a Ledger row like any
    /// other, and a build where it stops resolving refuses instead of guessing.
    public static let relocationPrimitives: [PrimitiveRequirement] = [
        .symbol(.axUIElementGetWindow),
    ]

    // MARK: Moving

    /// Writes `AXPosition` on the window behind this Window ID.
    ///
    /// It does not wait: this is the write, and confirming that the window came
    /// to rest is the caller's. The settable check before it is not ceremony,
    /// it is the difference between "the app refuses to be moved" and "the move
    /// silently did nothing", and the two need different reports.
    public static func move(_ window: WindowReference, to origin: CGPoint) throws {
        let element = try windowElement(for: window)
        try writeOrigin(origin, to: element)
        log.debug("moved window \(window.windowNumber, privacy: .public)")
    }

    /// Writes `AXSize` on the window behind this Window ID.
    ///
    /// Like `move` it does not wait and proves nothing: an application with a
    /// minimum size accepts the write and keeps the size it had, so the caller
    /// reads the window again and decides. It exists for one case, the window
    /// an application opens larger than the Virtual Display, where the
    /// alternative to shrinking it is leaving it on the person's screen.
    public static func resize(_ window: WindowReference, to size: CGSize) throws {
        let element = try windowElement(for: window)
        try writeSize(size, to: element)
        log.debug("""
            resized window \(window.windowNumber, privacy: .public) to \
            \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)
            """)
    }

    /// Reads only AXPosition and AXSize of the exact window. The body can have
    /// returned while WindowServer exposes its Stage Manager thumbnail; this
    /// reading supports return verification and never substitutes for staging.
    public static func frame(of window: WindowReference) throws -> CGRect? {
        let element = try windowElement(for: window)
        return frame(of: element)
    }

    /// Puts a window that Stage Manager stashed back on stage, at full size, on
    /// the Virtual Display.
    ///
    /// `kAXRaiseAction` is the primitive, measured on 26A5425a: it
    /// brings a stashed window back to full size, Stage Manager stashes
    /// whatever was on stage before it, and the target application does **not**
    /// become active, `NSApp.isActive` and `isKeyWindow` both staying false.
    /// The cost is the animation: 532 ms on Chrome, 19 ms on a cooperative
    /// window, which is why the budget is a whole second and why nothing may be
    /// posted to the window until the confirmation arrives.
    ///
    /// `expectedSize` is what full size means here. A stashed window reads as a
    /// thumbnail, 90 by 97 points in the measurement, so size is the signal
    /// that separates staged from stashed and the caller is the one that knows
    /// what the window measured before it was put away.
    @discardableResult
    public static func stage(
        _ window     : WindowReference,
        expectedSize : CGSize,
        within bounds: CGRect,
        timeout      : TimeInterval = 2,
        interval     : Duration     = .milliseconds(50)
    ) async throws -> WindowReference {

        let element = try windowElement(for: window)
        let result  = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard result == .success else {
            throw DisplayFailure.raiseFailed(windowNumber: window.windowNumber, code: result)
        }

        let confirmed = await waitForTwoAgreeingReadings(
            of      : window,
            timeout : timeout,
            interval: interval
        ) { reading in
            rectangleIsUsable(reading.frame)
                && bounds.contains(reading.frame)
                && sizesMatch(reading.frame.size, expectedSize)
        }
        if processIsGone(window.processID) {
            throw DisplayFailure.windowOwnerVanished(
                windowNumber: window.windowNumber,
                processID   : window.processID
            )
        }
        guard let confirmed else {
            throw DisplayFailure.stageNotConfirmed(
                windowNumber: window.windowNumber,
                lastFrame   : WindowServerProbe.geometry(of: window.windowNumber)?.frame
            )
        }
        log.debug("staged window \(window.windowNumber, privacy: .public)")
        return confirmed
    }

    /// Moves a window whose Window ID is momentarily not associable with any
    /// accessibility element, which happens while a display transition is in
    /// flight and is the one case where releasing a window back to the User
    /// Seat would otherwise fail.
    ///
    /// The fallback is allowed **only** on a single structural match: same
    /// title, same size within two points, centre still on the display the
    /// window is being taken off. Two matches are `ambiguousWindowMatch` and
    /// nothing is written, because a recovery that picks one of two windows can
    /// move a window the person is using.
    public static func recover(
        _ window           : WindowReference,
        expectedTitle      : String,
        expectedSize       : CGSize,
        sourceDisplayBounds: CGRect,
        to origin          : CGPoint
    ) throws {

        let windows = try windowElements(ofProcess: window.processID)

        if let exact = windows.first(where: { windowNumber(of: $0) == window.windowNumber }) {
            try writeOrigin(origin, to: exact)
            return
        }

        let matches = windows.filter { element in
            guard let frame = frame(of: element) else { return false }
            let sizeMatches = abs(frame.width  - expectedSize.width)  <= 2
                && abs(frame.height - expectedSize.height) <= 2
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            return title(of: element) == expectedTitle
                && sizeMatches
                && sourceDisplayBounds.contains(centre)
        }
        guard matches.count == 1, let unique = matches.first else {
            throw matches.isEmpty
                ? DisplayFailure.windowElementUnavailable(windowNumber: window.windowNumber)
                : DisplayFailure.ambiguousWindowMatch(
                    windowNumber: window.windowNumber,
                    matches     : matches.count
                )
        }
        try writeOrigin(origin, to: unique)
        log.debug("recovered window \(window.windowNumber, privacy: .public) structurally")
    }

    // MARK: Native fullscreen

    /// What `AXFullScreen` says about a window, as three answers and not two.
    ///
    /// The ticket asks for this distinction by name and the measurement earned
    /// it: an absent attribute means the state is **not readable**, never
    /// `false`, and `AXUIElementIsAttributeSettable` on an unsupported
    /// attribute returns success with `false`, so the settable check alone
    /// cannot tell "read only" from "not there". Both calls are read together
    /// here so that no caller has to remember.
    nonisolated public enum FullScreenReading: Sendable, Equatable {

        /// `AXFullScreen` is not on this window. The state is unknown.
        case unreadable(AXError)

        /// Readable, and the window refuses to be written. Measured per window:
        /// Resolve's Project Manager refuses while its main window accepts.
        case readOnly(Bool)

        /// Readable and writable.
        case writable(Bool)

        /// The fullscreen state when it is known, `nil` when it is not.
        public var value: Bool? {
            switch self {
                case .unreadable          : nil
                case .readOnly(let value) : value
                case .writable(let value) : value
            }
        }

        public var isNativeFullScreen: Bool { value == true }
    }

    /// Reads `AXFullScreen` and its writability in one pass.
    public static func fullScreen(of window: WindowReference) throws -> FullScreenReading {
        let element = try windowElement(for: window)
        var raw: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(element, fullScreenAttribute as CFString, &raw)
        guard read == .success, let number = raw as? NSNumber else { return .unreadable(read) }

        var isSettable = DarwinBoolean(false)
        let settable = AXUIElementIsAttributeSettable(element, fullScreenAttribute as CFString, &isSettable)
        return settable == .success && isSettable.boolValue
            ? .writable(number.boolValue)
            : .readOnly(number.boolValue)
    }

    /// Asks the window to enter or leave native fullscreen. It **does not
    /// wait**: measured on 26A428 the write returns in 10 to 98 ms and returns
    /// before anything happens, while the transition becomes observable 128 to
    /// 234 ms later in the background and 912 ms later when the window is the
    /// active one. Accepted and transitioned are two events and the caller
    /// confirms the second with `awaitFullScreen`.
    ///
    /// A window whose state is unreadable, or readable but not writable, is
    /// refused with its own case and left exactly where it is.
    public static func requestFullScreen(_ wanted: Bool, of window: WindowReference) throws {
        switch try fullScreen(of: window) {
            case .unreadable(let code):
                throw DisplayFailure.fullScreenStateUnreadable(
                    windowNumber: window.windowNumber,
                    code        : code
                )
            case .readOnly:
                throw DisplayFailure.fullScreenNotSettable(windowNumber: window.windowNumber)
            case .writable(let current) where current == wanted:
                return
            case .writable:
                break
        }
        let element = try windowElement(for: window)
        let result  = AXUIElementSetAttributeValue(element, fullScreenAttribute as CFString, wanted as CFBoolean)
        guard result == .success else {
            throw DisplayFailure.attributeWriteFailed(attribute: "AXFullScreen", code: result)
        }
        log.debug("requested fullscreen \(wanted, privacy: .public) on window \(window.windowNumber, privacy: .public)")
    }

    /// Waits for the **observable** end of a fullscreen transition: the
    /// attribute reads what was asked for and the window server hands back the
    /// same rectangle twice running. No fixed sleep is ever evidence here.
    ///
    /// The reference that comes back is re-read, never carried across the
    /// transition, and the frame on it is the window's normal frame, which is
    /// the one a return has to use. Measured: a window whose pre-fullscreen
    /// frame was off the display does not get it back, so remembering the frame
    /// from before would restore a rectangle macOS has already overruled.
    @discardableResult
    public static func awaitFullScreen(
        _ wanted: Bool,
        of window: WindowReference,
        timeout  : TimeInterval = 5,
        interval : Duration     = .milliseconds(20)
    ) async throws -> WindowReference {

        let deadline = Date().addingTimeInterval(timeout)
        var previous : WindowReference?

        repeat {
            if processIsGone(window.processID) {
                throw DisplayFailure.windowOwnerVanished(
                    windowNumber: window.windowNumber,
                    processID   : window.processID
                )
            }
            let state = try? fullScreen(of: window)
            if state?.value == wanted, let reading = WindowServerProbe.geometry(of: window.windowNumber),
               reading.hasSameIdentity(as: window) {
                if let previous,
                   VirtualWindowPlacementCheck.framesMatch(previous.frame, reading.frame) {
                    return reading
                }
                previous = reading
            } else {
                previous = nil
            }
            do { try await Task.sleep(for: interval) } catch { break }
        } while Date() < deadline

        throw DisplayFailure.fullScreenTransitionNotObserved(
            windowNumber: window.windowNumber,
            wanted      : wanted,
            lastFrame   : WindowServerProbe.geometry(of: window.windowNumber)?.frame
        )
    }

    /// True while the window's Space is the one on screen. Leaving fullscreen
    /// then takes the display to that Space and animates it back, which is
    /// 437 ms of the person's screen with Stage Manager off and 875 ms with it
    /// on, against 36 to 100 ms once the Space has gone.
    ///
    /// It reads the window server and never the frontmost application: the
    /// person can be in front of an application whose windows are off the
    /// display, in which case the Space never left and the frontmost PID says
    /// the opposite.
    public static func spaceIsOnScreen(for window: WindowReference) -> Bool {
        WindowServerProbe.isOnTheActiveSpace(windowNumber: window.windowNumber)
    }

    /// A `String` and not a `CFString`: the latter is not `Sendable`, and a
    /// static of it is a shared mutable global the compiler is right about.
    private static let fullScreenAttribute = "AXFullScreen"

    /// The one terminal condition a wait may take from outside itself. A
    /// missing window server reading is not a destruction, and the kit says so
    /// everywhere; a process that is gone is.
    private static func processIsGone(_ processID: Int32) -> Bool {
        NSRunningApplication(processIdentifier: processID).map(\.isTerminated) ?? true
    }

    // MARK: The Window ID behind an element

    /// `_AXUIElementGetWindow`: the Window ID of an accessibility window
    /// element, or `nil` when the element has none. Verified on 26A5425a and
    /// gated in the Ledger; there is no fallback, a build where it stops
    /// resolving refuses.
    ///
    /// It is public because it is the only bridge between the two identities a
    /// consumer holds, an accessibility element from its own observation layer
    /// and the Window ID the kit acts on, and every consumer that resolves one
    /// from the other would otherwise write this `dlsym` again.
    public static func windowNumber(
        of element: AXUIElement,
        table     : SymbolTable = .shared
    ) -> Int? {

        typealias GetWindow = @convention(c) (
            AXUIElement, UnsafeMutablePointer<CGWindowID>
        ) -> AXError

        guard let getWindow = table.function(.axUIElementGetWindow, as: GetWindow.self) else {
            return nil
        }
        var windowNumber = CGWindowID.zero
        guard getWindow(element, &windowNumber) == .success, windowNumber != 0 else {
            return nil
        }
        return Int(windowNumber)
    }

    // MARK: Resolution and writing

    /// The accessibility element behind a Window ID, through `AXWindows` first
    /// and through the application's focused and main window after it.
    ///
    /// The fallback is not a convenience. Measured on 26A428: a window in
    /// native fullscreen leaves the application's `AXWindows` list 330 ms
    /// (Stage Manager off) to 513 ms (on) after the focus moves elsewhere, at
    /// the moment its Space stops being the one on screen, and `AXWindows` then
    /// answers **success with an empty array**. Without these two extra routes
    /// the relocator cannot resolve, and therefore cannot read or write, the
    /// exact window this ticket is about.
    ///
    /// Identity is re-established on every route with `_AXUIElementGetWindow`
    /// against the Window ID that was asked for. "The application's focused
    /// window" is never accepted as "the window the caller means".
    ///
    /// The limit is stated rather than papered over: a window that is neither
    /// focused nor main and is not in `AXWindows` is not reachable by any
    /// public route, and this throws for it.
    private static func windowElement(for window: WindowReference) throws -> AXUIElement {
        let windows = try windowElements(ofProcess: window.processID)
        if let listed = windows.first(where: { windowNumber(of: $0) == window.windowNumber }) {
            return listed
        }
        let application = AXUIElementCreateApplication(window.processID)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                application, attribute as CFString, &value
            ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }

            let candidate = unsafeDowncast(value, to: AXUIElement.self)
            if windowNumber(of: candidate) == window.windowNumber { return candidate }
        }
        throw DisplayFailure.windowElementUnavailable(windowNumber: window.windowNumber)
    }

    private static func windowElements(ofProcess processID: Int32) throws -> [AXUIElement] {
        guard Permissions.preflight(.accessibility) else {
            throw DisplayFailure.accessibilityPermissionMissing
        }
        if let missing = SymbolTable.shared.firstUnresolved(of: relocationPrimitives) {
            throw DisplayFailure.primitiveUnavailable(missing)
        }
        guard let application = NSRunningApplication(processIdentifier: processID),
              !application.isTerminated
        else {
            throw DisplayFailure.processUnavailable(processID: processID)
        }

        let applicationElement = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        )
        // An empty list is returned and not thrown on. `AXWindows` answers
        // success with no windows at all while the only window of the process
        // sits in a fullscreen Space that is not on screen, and the caller has
        // two further routes to try before anything is unavailable.
        guard error == .success, let windows = value as? [AXUIElement] else {
            throw DisplayFailure.windowElementUnavailable(windowNumber: 0)
        }
        return windows
    }

    private static func writeOrigin(_ origin: CGPoint, to element: AXUIElement) throws {
        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXPositionAttribute as CFString,
            &isSettable
        )
        guard settableResult == .success, isSettable.boolValue else {
            throw DisplayFailure.attributeNotSettable("AXPosition")
        }

        var requested = origin
        guard let position = AXValueCreate(.cgPoint, &requested) else {
            throw DisplayFailure.attributeNotSettable("AXPosition")
        }
        let writeResult = AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            position
        )
        guard writeResult == .success else {
            throw DisplayFailure.attributeWriteFailed(attribute: "AXPosition", code: writeResult)
        }
    }

    private static func writeSize(_ size: CGSize, to element: AXUIElement) throws {
        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXSizeAttribute as CFString,
            &isSettable
        )
        guard settableResult == .success, isSettable.boolValue else {
            throw DisplayFailure.attributeNotSettable("AXSize")
        }

        var requested = size
        guard let value = AXValueCreate(.cgSize, &requested) else {
            throw DisplayFailure.attributeNotSettable("AXSize")
        }
        let writeResult = AXUIElementSetAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            value
        )
        guard writeResult == .success else {
            throw DisplayFailure.attributeWriteFailed(attribute: "AXSize", code: writeResult)
        }
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(of: element, kAXPositionAttribute, .cgPoint),
              let sizeValue     = axValue(of: element, kAXSizeAttribute,     .cgSize)
        else { return nil }

        var origin = CGPoint.zero
        var size   = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue,     .cgSize,  &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// One `AXValue` attribute of the requested kind, or `nil`.
    ///
    /// The type is checked with the runtime's own id before the cast, because
    /// `CFTypeRef as? AXValue` always succeeds in Swift and would hand
    /// `AXValueGetValue` something that is not an `AXValue` at all.
    private static func axValue(
        of element: AXUIElement,
        _ name    : String,
        _ type    : AXValueType
    ) -> AXValue? {

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }

        let boxed = unsafeDowncast(raw, to: AXValue.self)
        return AXValueGetType(boxed) == type ? boxed : nil
    }

    /// Two window sizes agree within the placement tolerance. Size is what
    /// separates a staged window from a stashed one: Stage Manager leaves the
    /// stash as a thumbnail, 90 by 97 points when it was measured.
    private static func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width  - rhs.width)  <= VirtualWindowPlacementCheck.placementTolerance
            && abs(lhs.height - rhs.height) <= VirtualWindowPlacementCheck.placementTolerance
    }

    // MARK: Confirmation

    /// Polls the window server until the same window satisfies `isSettled`
    /// twice in a row with an unchanged frame, or the timeout runs out.
    ///
    /// A reading that fails the predicate resets the count rather than ending
    /// the wait: a window on its way to the Virtual Display legitimately passes
    /// through frames that are neither the old one nor the new one.
    private static func waitForTwoAgreeingReadings(
        of window : WindowReference,
        timeout   : TimeInterval,
        interval  : Duration,
        isSettled : (WindowReference) -> Bool
    ) async -> WindowReference? {

        let deadline = Date().addingTimeInterval(timeout)
        var previous : WindowReference?

        repeat {
            // A process that exited is terminal. Measured: with the target
            // killed mid transition the loop went on polling a Window ID the
            // server had already forgotten and burned its whole budget to say
            // nothing. One missing reading still is not a destruction.
            if processIsGone(window.processID) { return nil }
            if let reading = WindowServerProbe.geometry(of: window.windowNumber),
               reading.hasSameIdentity(as: window),
               isSettled(reading) {
                if let previous,
                   VirtualWindowPlacementCheck.framesMatch(previous.frame, reading.frame) {
                    return reading
                }
                previous = reading
            } else {
                previous = nil
            }
            do { try await Task.sleep(for: interval) } catch { return nil }
        } while Date() < deadline

        return nil
    }
}

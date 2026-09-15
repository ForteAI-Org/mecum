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
/// the reason `docs/adr/0004` exists: `AXPosition` to move a window onto the
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

    private static func windowElement(for window: WindowReference) throws -> AXUIElement {
        let windows = try windowElements(ofProcess: window.processID)
        guard let element = windows.first(where: {
            windowNumber(of: $0) == window.windowNumber
        }) else {
            throw DisplayFailure.windowElementUnavailable(windowNumber: window.windowNumber)
        }
        return element
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
        guard error == .success, let windows = value as? [AXUIElement], !windows.isEmpty else {
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

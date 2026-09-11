//
//  DisplayFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import ApplicationServices
import CoreGraphics

/// TopologyStep names the point of a display configuration transaction that
/// refused, so a report can say which write failed without parsing a sentence.
/// Carried instead as a localized string inside the error, the only consumer
/// able to act on one is the one that prints it.
nonisolated public enum TopologyStep: Sendable, Equatable {

    /// `CGBeginDisplayConfiguration`.
    case openTransaction

    /// `CGConfigureDisplayOrigin` for the virtual display.
    case placeVirtualDisplay

    /// `CGConfigureDisplayOrigin` for one of the person's displays.
    case placePhysicalDisplay(CGDirectDisplayID)

    /// `CGCompleteDisplayConfiguration`.
    case commitTransaction
}

/// DisplayFailure is everything the Display Facility refuses to do: create the
/// virtual surface, attach it to the corner of the person's topology, take it
/// away again, or move a window onto it.
///
/// It carries fields, never prose. A version of this type that answers in
/// sentences makes every case unusable by anything but the label that displays
/// it; here the consumer writes the sentence and a report reads the codes.
nonisolated public enum DisplayFailure: Error, Sendable, Equatable {

    // MARK: The surface

    /// A private class, selector or symbol the Facility needs did not resolve
    /// on this build. The payload is the Ledger key, which is the same string
    /// `FacilityGate` reports as `unavailable(reason:)`: the Facility answers
    /// with a readiness, it does not trap.
    case primitiveUnavailable(String)

    /// `CGVirtualDisplay` refused `initWithDescriptor:`.
    case displayCreationFailed

    /// `CGVirtualDisplayMode` refused the requested width, height and rate.
    case modeRejected

    /// `applySettings:` returned false. The mode list was not accepted.
    case settingsRejected

    /// The private object published no usable `CGDirectDisplayID`.
    case displayIDUnavailable

    /// `CGGetOnlineDisplayList` or `CGGetActiveDisplayList` failed. This is
    /// never read as "the display is gone": an enumeration that did not answer
    /// says nothing about the display, so it fails closed instead.
    case displayEnumerationFailed(CGError)

    /// The topology was asked to accept a display CoreGraphics has not
    /// published yet. The caller has to let its application event loop turn
    /// between `create` and `configureTopology`.
    case notRegistered(
        displayID          : CGDirectDisplayID,
        isActive           : Bool,
        isOnline           : Bool,
        appearsInActiveList: Bool
    )

    /// AppKit never published an `NSScreen` for the display. Almost always the
    /// caller's run loop: `NSScreen` is refreshed by the application event
    /// loop, so a process that never pumps events waits forever.
    case screenRegistrationTimedOut(displayID: CGDirectDisplayID)

    // MARK: The topology

    /// There is no physical display to attach the virtual one to.
    case noPhysicalDisplays

    /// The computed corner origin does not fit in the `Int32` that
    /// `CGConfigureDisplayOrigin` takes.
    case originOutOfRange(CGPoint)

    /// One write of the display configuration transaction failed.
    case topologyConfigurationFailed(step: TopologyStep, code: CGError)

    /// The person's main display changed while the virtual one was being
    /// attached. The User Seat wins: the virtual display goes away.
    case mainDisplayChanged(expected: CGDirectDisplayID, actual: CGDirectDisplayID)

    /// One of the person's displays moved or was resized.
    case physicalDisplayMoved(CGDirectDisplayID)

    /// The topology restore was asked for while the virtual display is still in
    /// `CGGetOnlineDisplayList`. Restoring now would fight the display that is
    /// still attached.
    case displayStillOnline(CGDirectDisplayID)

    // MARK: The window

    /// Moving or staging a window needs Accessibility, and the kit never
    /// prompts on its own.
    case accessibilityPermissionMissing

    /// The process that owns the target window is gone.
    case processUnavailable(processID: Int32)

    /// No accessibility element could be associated with the Window ID, and no
    /// single structural match was available either.
    case windowElementUnavailable(windowNumber: Int)

    /// More than one window matched by title and size during recovery. A
    /// recovery that guesses is worse than one that refuses.
    case ambiguousWindowMatch(windowNumber: Int, matches: Int)

    /// The application exposes the attribute but does not let it be written.
    case attributeNotSettable(String)

    /// The accessibility write itself failed.
    case attributeWriteFailed(attribute: String, code: AXError)

    /// `kAXRaiseAction` failed.
    case raiseFailed(windowNumber: Int, code: AXError)

    /// The window did not reach the requested origin, confirmed twice by the
    /// window server, inside the attempt budget.
    case placementNotConfirmed(windowNumber: Int, lastFrame: CGRect?)

    /// The window was raised but never came back at full size inside the
    /// virtual display, confirmed twice. Stage Manager kept it stashed.
    case stageNotConfirmed(windowNumber: Int, lastFrame: CGRect?)
}

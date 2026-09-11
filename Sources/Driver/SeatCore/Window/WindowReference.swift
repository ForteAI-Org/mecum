//
//  WindowReference.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// WindowReference is the target a consumer observed: its process lifetime,
/// Window ID, owning WindowServer connection and frame in Quartz coordinates.
/// Nothing here knows about accessibility trees, roles or window titles: an app
/// that rebuilds its whole control hierarchy still owns the same window.
public struct WindowReference: Sendable, Equatable {

    /// The complete identity attested by WindowServer. `nil` is retained only
    /// so source that constructs the old PID and Window ID shape still builds;
    /// every input path refuses such a reference before changing target state.
    public let identity: WindowIdentity?

    /// The process that owns the window, as reported by the observation layer.
    public let processID: Int32

    /// The Window ID, stable for the window's lifetime and reused afterwards,
    /// which is why identity is always checked together with `processID`.
    public let windowNumber: Int

    /// The window frame in Quartz coordinates, origin at the top left of the
    /// main display. It is a reading, not a request: moving a window produces a
    /// new reference rather than mutating this one.
    public let frame: CGRect

    /// Creates an attested reference from a WindowServer identity reading.
    public init(identity: WindowIdentity, frame: CGRect) {
        self.identity     = identity
        self.processID    = identity.processID
        self.windowNumber = identity.windowNumber
        self.frame        = frame
    }

    /// Creates an unverified compatibility reference.
    ///
    /// Input and adoption refuse this value because PID and Window ID can both
    /// be reused. Resolve it through `WindowServerProbe.geometry(of:)`, then
    /// preserve the returned identity when changing only its frame.
    public init(processID: Int32, windowNumber: Int, frame: CGRect) {
        self.identity     = nil
        self.processID    = processID
        self.windowNumber = windowNumber
        self.frame        = frame
    }

    /// Two references describe the same window when process and Window ID
    /// match across the same attested lifetime and owner connection; the frame
    /// is expected to change while the window is on the seat. An unverified
    /// compatibility reference never establishes identity, even against
    /// another unverified value with the same reusable numbers.
    public func hasSameIdentity(as other: WindowReference) -> Bool {
        guard let identity, let otherIdentity = other.identity else { return false }
        return identity == otherIdentity
    }

    /// Returns the same attested target with a newer geometry reading.
    public func replacingFrame(_ frame: CGRect) -> WindowReference {
        guard let identity else {
            return WindowReference(
                processID   : processID,
                windowNumber: windowNumber,
                frame       : frame
            )
        }
        return WindowReference(identity: identity, frame: frame)
    }
}

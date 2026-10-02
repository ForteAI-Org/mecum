//
//  ResolvedInputEndpoint.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics

/// InputEndpointKind separates the two questions an endpoint can answer,
/// because mouse and keyboard do not have the same contract.
///
/// A pointer endpoint is decided by a point: the window the event has to land
/// in is the one drawn under that point. A keyboard context is decided by the
/// focused node of the topmost modal surface and by nothing the mouse did, so
/// the two are resolved from different evidence and invalidated by different
/// changes.
nonisolated public enum InputEndpointKind: Sendable, Equatable {

    /// The window one mouse gesture is addressed to.
    case pointer

    /// The window that owns the focused node keys are addressed to.
    case keyboardContext
}

/// InputEndpointEvidence is where the endpoint's Window ID came from. It is
/// kept on the value because "this is the window" and "this is how I know" are
/// different facts, and a Receipt that carries only the first one cannot be
/// audited afterwards.
nonisolated public enum InputEndpointEvidence: Sendable, Equatable {

    /// `_AXUIElementGetWindow` on the concrete node reached by the observational
    /// descent, with the whole WindowServer chain resolved from that Window ID.
    /// The accessibility PID of that node is a separate datum and may be the
    /// host's: it is carried, never substituted for the owner.
    case accessibilityNodeIdentity

    /// The surface the seat already holds, when the descent proved the node
    /// belongs to it rather than to a remote content window.
    case attestedSurfaceItself

    /// The surface the seat already holds, read as one accessibility leaf: a
    /// top-level modal whose whole interface accessibility sees nothing in, so
    /// nothing inside it can be another recipient.
    case leafSurface

    /// AX names a focused window but no focused control. A complete bounded
    /// reading ties its input-bearing descendants to that window; only proven
    /// inert, windowless leaves may have no matching Window ID.
    case focusedWindowWithoutFocusedControl

    /// AX names the selected modal surface but no focused control, or only the
    /// surface's own window node. A bounded, complete scan of that exact
    /// surface found one focused descendant whose WindowServer identity and
    /// geometry were attested as the recipient.
    /// This is deliberately distinct from a merely remote modal child: the
    /// positive AX focused fact, not the modal relation alone, names the key
    /// destination.
    case focusedSurfaceDescendant

    /// The focused control, or the node under the point, answers no Window ID,
    /// and a bounded, complete scan of the attested surface found exactly one
    /// other window named by its descendants: an out of process sheet's
    /// content, whose own controls carry no window.
    case remoteContentOfSurface

    /// The surface the seat already holds, for content it draws itself and
    /// accessibility gives no Window ID, such as a web page. The node under the
    /// point, or the focused control, belongs to the assigned process, and so
    /// does every node between it and the nearest one naming a window, which is
    /// the surface. Only for a surface with no attested modal relation (ADR 0014).
    case windowlessContentOfSurface
}

/// InputEndpointRelation is the endpoint's relation to the logical surface the
/// seat is operating: either that surface itself, or a window of another
/// process drawn inside it.
///
/// The surface a relation is stated against is `logicalSurface` on the
/// endpoint. Remote content is never a relation to a helper *process*, because
/// a PID is not a relation: the same service can host a second panel for
/// somebody else, and that panel is not this one.
nonisolated public enum InputEndpointRelation: Sendable, Equatable {

    /// The endpoint is the logical surface the seat holds.
    case logicalSurface

    /// The endpoint is a window of another process drawn inside the surface.
    case remoteContent
}

/// Why an endpoint resolved earlier is no longer the one a Command may use.
/// Each case is one of the events that has to retire an endpoint, named so the
/// refusal says which one happened rather than answering "stale".
nonisolated public enum InputEndpointInvalidation: Error, Sendable, Equatable {

    /// The endpoint's own deadline passed.
    case expired

    /// The seat is operating a different surface now, or the relation the
    /// endpoint was attested under no longer holds.
    case relationNoLongerValid

    /// The Window ID no longer resolves to the same process lifetime and owner
    /// connection: the window closed, the id was handed out again, or the
    /// helper that owned it was replaced or died.
    case identityChanged

    /// The focused node moved to another window, which retires a keyboard
    /// context and says nothing about a pointer endpoint.
    case focusedNodeChanged

    /// A newer selection generation replaced the one it was resolved under.
    case selectionSuperseded
}

/// ResolvedInputEndpoint is the window one Command is actually addressed to,
/// with everything that had to be proved to address it.
///
/// It exists because the assigned application, the logical surface, the source
/// of the capture and the recipient of the input are four different things. An
/// open and save panel is the case that forced it apart: measured on 26A428,
/// the sheet belonged to the host application and its content belonged to
/// `com.apple.appkit.xpc.openAndSavePanelService`, with a different Window ID,
/// a different owner connection and a different PID, while accessibility kept
/// answering the host's PID for the control that was clicked.
///
/// It is internal to the kit. A consumer never builds one and never receives
/// one: the value the consumer holds is a `SeatObservationReference`, and this
/// is what the seat resolves from it immediately before handing the Command to
/// the driver, so the driver's own identity and geometry checks run against the
/// window that will receive the events instead of against the one the pixels
/// came from.
nonisolated public struct ResolvedInputEndpoint: Sendable, Equatable {

    /// Which of the two contracts this endpoint answers.
    public let kind: InputEndpointKind

    /// The complete WindowServer identity of the recipient: Window ID, owner
    /// connection and the process lifetime behind it. A PID alone never
    /// reaches here.
    public let identity: WindowIdentity

    /// The recipient's geometry, read together with its identity and carrying
    /// the display scale, so a point expressed against it is expressed against
    /// one coherent reading.
    public let geometry: WindowGeometryObservation

    /// How the Window ID was established.
    public let evidence: InputEndpointEvidence

    /// The endpoint's relation to the logical surface below.
    public let relation: InputEndpointRelation

    /// The surface the seat is operating, which the relation is stated against.
    public let logicalSurface: WindowIdentity

    /// The PID accessibility reported for the node the descent stopped at. It
    /// is a separate datum from `identity.processID` and is expected to differ
    /// from it for remote content: it is kept for the diagnosis and is never
    /// the process anything is posted to.
    public let accessibilityProcessID: Int32

    /// The selection generation the endpoint was resolved under.
    public let selectionGeneration: UInt64

    /// The monotonic instant the resolution happened at.
    public let resolvedAtNanoseconds: UInt64

    /// The monotonic instant after which the endpoint has to be resolved again.
    public let expiresAtNanoseconds: UInt64

    /// The observed keyboard window, from the focused control or the complete
    /// focused-window proof named by `evidence`; `nil` for a pointer endpoint.
    /// A context whose focus moved elsewhere is retired even while its own
    /// window remains alive. The window-only proof is repeated before posting.
    public let focusedNodeWindowNumber: Int?

    /// Creates an endpoint only from geometry that carries a complete attested
    /// identity and from a deadline that is in the future at the moment of the
    /// resolution. There is no other way to make one, so an incoherent
    /// window, connection and process combination cannot become a recipient.
    package init?(
        kind                   : InputEndpointKind,
        geometry               : WindowGeometryObservation,
        evidence               : InputEndpointEvidence,
        relation               : InputEndpointRelation,
        logicalSurface         : WindowIdentity,
        accessibilityProcessID : Int32,
        selectionGeneration    : UInt64,
        resolvedAtNanoseconds  : UInt64,
        expiresAtNanoseconds   : UInt64,
        focusedNodeWindowNumber: Int? = nil
    ) {
        guard let identity = geometry.window.identity,
              identity.processID == geometry.window.processID,
              identity.windowNumber == geometry.window.windowNumber,
              resolvedAtNanoseconds < expiresAtNanoseconds
        else { return nil }

        if relation == .remoteContent, identity == logicalSurface { return nil }

        self.identity                = identity
        self.kind                    = kind
        self.geometry                = geometry
        self.evidence                = evidence
        self.relation                = relation
        self.logicalSurface          = logicalSurface
        self.accessibilityProcessID  = accessibilityProcessID
        self.selectionGeneration     = selectionGeneration
        self.resolvedAtNanoseconds   = resolvedAtNanoseconds
        self.expiresAtNanoseconds    = expiresAtNanoseconds
        self.focusedNodeWindowNumber = focusedNodeWindowNumber
    }

    /// Why this endpoint may no longer be used, `nil` when it still may.
    ///
    /// Every fact it compares is supplied by the caller from a fresh reading:
    /// this decides, it does not read, which is what lets the whole table of
    /// retirements be proved without a window on the screen. `currentIdentity`
    /// is `nil` for a Window ID that no longer resolves at all, which is a
    /// closed window and an identity change alike.
    public func invalidation(
        at now              : UInt64,
        selectionGeneration : UInt64,
        logicalSurface      : WindowIdentity?,
        currentIdentity     : WindowIdentity?,
        focusedNodeWindowNumber: Int? = nil
    ) -> InputEndpointInvalidation? {

        guard now < expiresAtNanoseconds                       else { return .expired }
        guard selectionGeneration == self.selectionGeneration  else { return .selectionSuperseded }
        guard logicalSurface == self.logicalSurface            else { return .relationNoLongerValid }
        guard let currentIdentity, currentIdentity == identity else { return .identityChanged }

        guard kind == .keyboardContext, let expected = self.focusedNodeWindowNumber else {
            return nil
        }
        guard focusedNodeWindowNumber == expected else { return .focusedNodeChanged }
        return nil
    }
}

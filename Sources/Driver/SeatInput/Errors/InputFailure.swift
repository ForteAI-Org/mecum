//
//  InputFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore

/// PreparationStep remains visible through SeatInput for source compatibility.
/// Its value lives in SeatCore so Receipt and progress types share one enum.
public typealias PreparationStep = SeatCore.PreparationStep

/// InputFailure is everything the Input Facility refuses to do. It carries
/// fields and codes, never prose: the consumer writes the sentence, a test
/// asserts on the case, and the compatibility report prints the numbers.
///
/// A Command-specific case refuses before that Command's first event. A
/// `restoreFailed` value describes cleanup only: its surrounding Receipt or
/// progress record says whether a Command was posted and prevents replay from
/// being inferred from the error alone.
nonisolated public enum InputFailure: Error, Sendable, Equatable {

    // MARK: The Facility

    /// A private primitive the Facility needs did not resolve on this build.
    /// The payload is the Ledger key, so it matches what `FacilityGate` reports
    /// as `unavailable(reason:)`.
    case primitiveUnavailable(String)

    /// The gate refused: an unknown build, a missing grant or a self check that
    /// did not pass. Fail closed, spec section 6 and `docs/adr/0001`. The
    /// readiness carries which of the three it was.
    case facilityUnavailable(FacilityReadiness)

    /// `SLSMainConnectionID` answered zero: this process has no window server
    /// connection, so nothing can be routed.
    case mainConnectionUnavailable

    /// `CGEventSource(.privateState)` refused. Without a private source the
    /// events would carry the person's own state, so there is no fallback.
    case eventSourceUnavailable

    /// Focus recovery has paused this driver before this command was posted.
    case inputPaused

    // MARK: The target

    /// The process that owns the target window is gone.
    case processUnavailable(processID: Int32)

    /// The Window ID is zero or does not fit the window server's `UInt32`.
    case invalidWindowNumber(Int)

    /// `SLSGetWindowOwner` did not confirm an owning connection for the window,
    /// which is the identity re-read that stands in for a window list scan.
    case windowOwnerUnavailable(windowNumber: Int, code: Int32)

    /// The caller supplied only a PID and Window ID. Both can be reused after
    /// their former owners terminate, so the driver cannot prove this is the
    /// window the caller observed and refuses before changing target state.
    case windowIdentityUnverified(processID: Int32, windowNumber: Int)

    /// A fresh WindowServer ownership chain no longer equals the one attached
    /// to the reference. `observed` is nil when any link could not be proved.
    case windowIdentityChanged(expected: WindowIdentity, observed: WindowIdentity?)

    // MARK: The Command

    /// A sequence with no Command in it.
    case noCommands

    /// A `text` Command with nothing to type.
    case emptyText

    /// A coordinate that is not finite. A NaN posted to another process is a
    /// click at an unknown place.
    case invalidLocation

    /// A mouse coordinate was built through the legacy initializer and has no
    /// attested geometry reading. Current geometry cannot be attached at send
    /// time to certify an older point.
    case coordinateObservationMissing

    /// The driver could not obtain a fresh identity, frame and single-display
    /// scale for the target immediately before constructing the Command.
    case currentCoordinateGeometryUnavailable

    /// One of the geometry values required by the transform is malformed.
    case invalidCoordinateGeometry

    /// The coordinate was observed on a different window lifetime than the
    /// current target. Either value may be nil only for unverified legacy data.
    case coordinateIdentityChanged(expected: WindowIdentity?, observed: WindowIdentity?)

    /// The target changed size. Only a pure translation preserves every local
    /// point without a fresh observation of the window's layout.
    case coordinateGeometryChanged(observed: CGRect, current: CGRect)

    /// The target moved to output with a different point-to-pixel scale.
    case coordinateScaleChanged(observed: CGFloat, current: CGFloat)

    /// The local point lies outside the window frame that produced it.
    case coordinateOutsideObservedWindow(point: CGPoint, frame: CGRect)

    /// The supplied screen point and window-local point do not describe the
    /// same location under the geometry that was bound at observation time.
    case coordinateSpacesDisagree

    /// A drag needs a start, at least one intermediate point and an end.
    case invalidDragPath(pointCount: Int)

    /// CoreGraphics did not create one of the events.
    case eventCreationFailed

    // MARK: The record

    /// `SLEventRecordPointer` returned nothing for an event the kit created.
    case eventRecordUnavailable

    /// The record's declared length at 0x04 is not 0xF8. Nothing is written and
    /// nothing is posted.
    case unsupportedEventRecord(declared: UInt32, expected: UInt32)

    /// A bounded read or write of the record was refused. The audited exception
    /// to "no unsafe unwraps" is this path, and this is the bound.
    case recordOffsetOutOfBounds(offset: Int, width: Int, length: Int)

    // MARK: The Preparation

    /// `SLPSPostEventRecordTo` refused one of the Preparation records. No
    /// Command event is sent. The failed record's effect is uncertain, so
    /// `InputPreparationFailure` also reports the bounded cleanup attempt.
    case preparationFailed(step: PreparationStep, code: Int32)

    /// The restore record was refused after the Preparation was applied. The
    /// surrounding Receipt or progress record carries delivery and recovery.
    case restoreFailed(code: Int32)
}
